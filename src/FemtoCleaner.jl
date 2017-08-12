module FemtoCleaner

using GitHub
using GitHub: GitHubAPI, GitHubWebAPI
using HttpCommon
using Deprecations
using CSTParser
using Deprecations: isexpr
using Revise
using MbedTLS
using JSON
using AbstractTrees: children

function with_cloned_repo(f, api::GitHubWebAPI, repo, auth)
    creds = LibGit2.UserPasswordCredentials("x-access-token", auth.token)
    repo_url = "https://@github.com/$(get(repo.full_name))"
    local_dir = mktempdir()
    try
        lrepo = LibGit2.clone(repo_url, local_dir; payload=Nullable(creds))
        f((lrepo, local_dir))
    finally
        rm(local_dir, force=true, recursive=true)
    end
end

function with_pr_branch(f, repo, auth)
    with_cloned_repo(repo, auth) do x
        LibGit2.branch!(lrepo, "fbot/deps", track=LibGit2.Consts.REMOTE_ORIGIN)
        f(x)
    end
end

function process_deprecations(lrepo, local_dir)
    vers = Pkg.Reqs.parse(joinpath(local_dir, "REQUIRE"))
    deps = Deprecations.applicable_deprecations(vers)
    changed_any = false
    for (root, dirs, files) in walkdir(local_dir)
        for file in files
            fpath = joinpath(root, file)
            endswith(fpath, ".jl") || continue
            # Iterate. Some rewrites may expose others
            while Deprecations.edit_file(fpath, deps)
                changed_any = true
            end
            changed_any && LibGit2.add!(lrepo, relpath(fpath, local_dir))
        end
    end
    changed_any
end

function clone_and_process(api, repo, auth)
    with_cloned_repo(x->process_deprecations(x...), api, repo, auth)
end

function push_repo(api::GitHubWebAPI, repo)
    LibGit2.push(repo, refspecs = ["+HEAD:refs/heads/fbot/deps"], force=true)
end

function apply_deprecations(api::GitHubAPI, lrepo, local_dir, commit_sig, repo, auth; issue_number = 0)
    changed_any = process_deprecations(lrepo, local_dir)
    if changed_any
        LibGit2.commit(lrepo, "Fix deprecations"; author=commit_sig, committer=commit_sig)
        push_repo(api, lrepo)
    end
    if issue_number != 0
        if changed_any
            create_pull_request(api, repo, auth=auth, params = Dict(
                    :issue => issue_number,
                    :base => get(repo.default_branch),
                    :head => "fbot/deps"
                )
            )
        else
            create_comment(api, repo, issue_number, :issue, params = Dict(
                :body => "No applicable deprecations were found in this repository."
            ), auth=auth)
        end
    else
        if changed_any
            create_pull_request(api, repo, auth=auth, params = Dict(
                    :title => "Fix deprecations",
                    :body => "I fixed a number of deprecations for you",
                    :base => get(repo.default_branch),
                    :head => "fbot/deps"
                )
            )
        else
            println("Processing complete: no changes made")
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

function dry_run(repo_url)
    local_dir = mktempdir()
    try
        lrepo, changed_any = clone_and_process(local_dir, repo_url)
        cd(local_dir) do
            run(`git status`)
            run(`git diff --cached`)
        end
    finally
        println(local_dir)
        #rm(local_dir, force=true, recursive=true)
    end
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
    return HttpCommon.Response(200)
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
    GitHub.run(listener, host=IPv4(0,0,0,0), port=10000+app_id)
    wait()
end

end # module
