module FemtoCleaner

using GitHub
using GitHub: GitHubAPI, GitHubWebAPI
using HTTP
using Deprecations
using CSTParser
using Deprecations: isexpr
using Revise
using MbedTLS
using JSON
using AbstractTrees: children
using Base: LibGit2

# Remove when https://github.com/JuliaWeb/HTTP.jl/pull/106 is resolved
HTTP.escape(v::Symbol) = HTTP.escape(string(v))

function with_cloned_repo(f, api::GitHubWebAPI, repo, auth)
    creds = LibGit2.UserPasswordCredentials(String(copy(Vector{UInt8}("x-access-token"))), String(copy(Vector{UInt8}(auth.token))))
    repo_url = "https://github.com/$(get(repo.full_name))"
    local_dir = mktempdir()
    try
        enabled = gc_enable(false)
        lrepo = LibGit2.clone(repo_url, local_dir; payload=Nullable(creds))
        gc_enable(enabled)
        f((lrepo, local_dir))
    finally
        rm(local_dir, force=true, recursive=true)
    end
end

function with_pr_branch(f, api, repo, auth)
    with_cloned_repo(api, repo, auth) do x
        LibGit2.branch!(lrepo, "fbot/deps", track=LibGit2.Consts.REMOTE_ORIGIN)
        f(x)
    end
end

if VERSION < v"0.7.0-DEV.695"
    include("blame.jl")
else
    using LibGit2: GitBlame
end

function process_deprecations(lrepo, local_dir; is_julia_itself=false)
    if is_julia_itself
        ver = readstring(joinpath(local_dir, "VERSION"))
        hunk = GitBlame(lrepo, "VERSION")[1]
        l, r = LibGit2.revcount(lrepo, string(hunk.orig_commit_id), "HEAD")
        vers = Pkg.Reqs.parse(IOBuffer("julia $ver+$(l+r)"))
    else
        vers = Pkg.Reqs.parse(joinpath(local_dir, "REQUIRE"))
    end
    deps = Deprecations.applicable_deprecations(vers)
    changed_any = false
    problematic_files = String[]
    for (root, dirs, files) in walkdir(local_dir)
        for file in files
            fpath = joinpath(root, file)
            (endswith(fpath, ".jl") || endswith(fpath, ".md")) || continue
            # Iterate. Some rewrites may expose others
            max_iterations = 30
            exceeded_iterations = false
            iteration_counter = 1
            while Deprecations.edit_file(fpath, deps, endswith(fpath, ".jl") ? edit_text : edit_markdown)
                if iteration_counter > max_iterations
                    exceeded_iterations = true
                    push!(problematic_files, file)
                    break
                end
                iteration_counter += 1
                changed_any = true
            end
            changed_any && !(exceeded_iterations) && LibGit2.add!(lrepo, relpath(fpath, local_dir))
        end
    end
    changed_any, problematic_files
end

function push_repo(api::GitHubWebAPI, repo, auth; force=true)
    creds = LibGit2.UserPasswordCredentials(String(copy(Vector{UInt8}("x-access-token"))), String(copy(Vector{UInt8}(auth.token))))
    enabled = gc_enable(false)
    LibGit2.push(repo, refspecs = ["+HEAD:refs/heads/fbot/deps"], force=force,
        payload=Nullable(creds))
    gc_enable(enabled)
end

function apply_deprecations(api::GitHubAPI, lrepo, local_dir, commit_sig, repo, auth; issue_number = 0)
    is_julia_itself = GitHub.name(repo) == "JuliaLang/julia"
    changed_any, problematic_files = process_deprecations(lrepo, local_dir; is_julia_itself=is_julia_itself)
    if changed_any
        LibGit2.commit(lrepo, "Fix deprecations"; author=commit_sig, committer=commit_sig, parent_ids=[LibGit2.GitHash(lrepo, "HEAD")])
        push_repo(api, lrepo, auth)
    end
    if issue_number != 0
        if changed_any
            create_pull_request(api, repo, auth=auth, params = Dict(
                    :issue => issue_number,
                    :base => get(repo.default_branch),
                    :head => "fbot/deps"
                )
            )
            if !isempty(problematic_files)
                create_comment(api, repo, issue_number, :pr, auth=auth, params = Dict(
                    :body => string("Failed to process the following files: ",
                                    join("`" .* problematic_files .* "`", ", "),
                                    ". :(")
                    )
                )
            end
            println("Created pull request for $(GitHub.name(repo))")
        else
            create_comment(api, repo, issue_number, :issue, params = Dict(
                :body => "No applicable deprecations were found in this repository."
            ), auth=auth)
            println("Processing complete for $(GitHub.name(repo)): no changes made")
        end
    else
        if changed_any
            body = "I fixed a number of deprecations for you"
            if !isempty(problematic_files)
                body *= string(", but I failed to process the following files: ",
                               join("`" .* problematic_files .* "`", ", "),
                               ". :(")
            end
            create_pull_request(api, repo, auth=auth, params = Dict(
                    :title => "Fix deprecations",
                    :body => body,
                    :base => get(repo.default_branch),
                    :head => "fbot/deps"
                )
            )
            println("Created pull request for $(GitHub.name(repo))")
        else
            println("Processing complete for $(GitHub.name(repo)): no changes made")
        end
    end
end

function my_diff_tree(repo::LibGit2.GitRepo, oldtree::LibGit2.GitTree, newtree::LibGit2.GitTree; pathspecs::AbstractString="")
    diff_ptr_ptr = Ref{Ptr{Void}}(C_NULL)
    @LibGit2.check ccall((:git_diff_tree_to_tree, :libgit2), Cint,
                  (Ptr{Ptr{Void}}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{LibGit2.DiffOptionsStruct}),
                   diff_ptr_ptr, repo.ptr, oldtree.ptr, newtree.ptr, isempty(pathspecs) ? C_NULL : pathspecs)
    return LibGit2.GitDiff(repo, diff_ptr_ptr[])
end

function apply_deprecations_if_updated(api::GitHubAPI, lrepo, local_dir, before, after, commit_sig, repo, auth)
    before = LibGit2.GitCommit(lrepo, before)
    after = LibGit2.GitCommit(lrepo, after)
    delta = my_diff_tree(lrepo, LibGit2.peel(before), LibGit2.peel(after); pathspecs="REQUIRE")[1]
    old_blob = LibGit2.GitBlob(lrepo, delta.old_file.id)
    new_blob = LibGit2.GitBlob(lrepo, delta.new_file.id)
    vers_old = Pkg.Reqs.parse(IOBuffer(LibGit2.content(old_blob)))
    vers_new = Pkg.Reqs.parse(IOBuffer(LibGit2.content(new_blob)))
    if vers_new["julia"] != vers_old["julia"]
        apply_deprecations(api, lrepo, local_dir, commit_sig, repo, auth)
    end
end

function dry_run(repo_url; show_diff = true)
    local_dir = mktempdir()
    successful = true
    try
        enabled = gc_enable(false)
        lrepo = LibGit2.clone(repo_url, local_dir)
        gc_enable(enabled)
        process_deprecations(lrepo, local_dir; is_julia_itself=contains(repo_url, "JuliaLang/julia"))
    catch e
        bt = catch_backtrace()
        Base.display_error(STDERR, e, bt)
        successful = false
    finally
        if show_diff
            cd(local_dir) do
                run(`git status`)
                run(`git diff --cached`)
            end
        end
        rm(local_dir, force=true, recursive=true)
    end
    return successful
end

include("interactions.jl")
include("autodeployment.jl")

const autodeployment_enabled = haskey(ENV, "FEMTOCLEANER_AUTODEPLOY") ?
    ENV["FEMTOCLEANER_AUTODEPLOY"] == "yes" : false

function event_callback(api::GitHubAPI, app_name, app_key, app_id, sourcerepo_installation,
                        commit_sig, listener, bug_repository, event)
    # On installation, process every repository we just got installed into
    if event.kind == "installation"
        jwt = GitHub.JWTAuth(app_id, app_key)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        for repo in event.payload["repositories"]
            repo = GitHub.repo(api, GitHub.Repo(repo); auth=auth)
            with_cloned_repo(api, repo, auth) do x
                apply_deprecations(api, x..., commit_sig, repo, auth)
            end
        end
    elseif event.kind == "installation_repositories"
        jwt = GitHub.JWTAuth(app_id, app_key)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        for repo in event.payload["repositories_added"]
            repo = GitHub.repo(api, GitHub.Repo(repo); auth=auth)
            with_cloned_repo(api, repo, auth) do x
                apply_deprecations(api, x..., commit_sig, repo, auth)
            end
        end
    elseif event.kind == "pull_request_review"
        jwt = GitHub.JWTAuth(app_id, app_key)
        pr_response(api, event, jwt, commit_sig, app_name, sourcerepo_installation, bug_repository)
    elseif event.kind == "push"
        jwt = GitHub.JWTAuth(app_id, app_key)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        repo = Repo(event.payload["repository"])
        # Check if REQUIRE was updated
        for commit in event.payload["commits"]
            if "REQUIRE" in commit["modified"]
                with_cloned_repo(api, repo, auth) do x
                    apply_deprecations_if_updated(api, x...,
                        event.payload["before"], event.payload["after"],
                        commit_sig, repo, auth)
                end
                break
            end
        end
        maybe_autdodeploy(event, listener, jwt, sourcerepo_installation, autodeployment_enabled)
    elseif event.kind == "issues" && event.payload["action"] == "opened"
        jwt = GitHub.JWTAuth(app_id, app_key)
        iss = Issue(event.payload["issue"])
        repo = Repo(event.payload["repository"])
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        if lowercase(get(iss.title)) == "run femtocleaner"
            with_cloned_repo(api, repo, auth) do x
                apply_deprecations(api, x..., commit_sig, repo, auth; issue_number = get(iss.number))
            end
        end
    end
    return HTTP.Response(200)
end

function run_server()
    app_key = MbedTLS.PKContext()
    MbedTLS.parse_key!(app_key, haskey(ENV, "FEMTOCLEANER_PRIVKEY") ? ENV["FEMTOCLEANER_PRIVKEY"] : readstring(joinpath(dirname(@__FILE__),"..","privkey.pem")))
    app_id = parse(Int, strip(haskey(ENV, "FEMTOCLEANER_APPID") ? ENV["FEMTOCLEANER_APPID"] : readstring(joinpath(dirname(@__FILE__),"..","app_id"))))
    secret = haskey(ENV, "FEMTOCLEANER_SECRET") ? ENV["FEMTOCLEANER_SECRET"] : nothing
    sourcerepo_installation = haskey(ENV, "FEMTOCLEANER_INSTALLATION") ? parse(Int, ENV["FEMTOCLEANER_INSTALLATION"]) : 0
    bug_repository = haskey(ENV, "FEMTOCLEANER_BUGREPO") ? ENV["FEMTOCLEANER_BUGREPO"] : ""
    (secret == nothing) && warn("Webhook secret not set. All events will be accepted. This is an insecure configuration!")
    jwt = GitHub.JWTAuth(app_id, app_key)
    app_name = get(GitHub.app(; auth=jwt).name)
    commit_sig = LibGit2.Signature("$(app_name)[bot]", "$(app_name)[bot]@users.noreply.github.com")
    api = GitHub.DEFAULT_API
    @async update_existing_repos(api, commit_sig, app_id, app_key)
    local listener
    listener = GitHub.EventListener(secret=secret) do event
        revise()
        Base.invokelatest(event_callback, api, app_name, app_key, app_id,
                          sourcerepo_installation, commit_sig, listener, bug_repository, event)
    end
    GitHub.run(listener, IPv4(0,0,0,0), 10000+app_id)
    wait()
end

end # module
