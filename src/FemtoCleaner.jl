module FemtoCleaner

# For interactive development
using Revise

using Base.Distributed
using GitHub
using GitHub: GitHubAPI, GitHubWebAPI, Checks
using HTTP
using Deprecations
using CSTParser
using Deprecations: isexpr
using MbedTLS
using JSON
using AbstractTrees: children
using Base: LibGit2

include("workqueue.jl")

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

function deprecations_for_repo(lrepo, local_dir, is_julia_itself)
    if is_julia_itself
        ver = readstring(joinpath(local_dir, "VERSION"))
        hunk = GitBlame(lrepo, "VERSION")[1]
        l, r = LibGit2.revcount(lrepo, string(hunk.orig_commit_id), "HEAD")
        vers = Pkg.Reqs.parse(IOBuffer("julia $ver+$(l+r)"))
    else
        vers = Pkg.Reqs.parse(joinpath(local_dir, "REQUIRE"))
    end
    deps = Deprecations.applicable_deprecations(vers)

end

function process_deprecations(lrepo, local_dir; is_julia_itself=false, deps = deprecations_for_repo(lrepo, local_dir, is_julia_itself))
    changed_any = false
    problematic_files = String[]
    all_files = String[]
    all_files = String[]
    for (root, dirs, files) in walkdir(local_dir)
        for file in files
            fpath = joinpath(root, file)
            (endswith(fpath, ".jl") || endswith(fpath, ".md")) || continue
            file == "NEWS.md" && continue
            push!(all_files, fpath)
        end
    end
    max_iterations = 30
    iteration_counter = fill(0, length(all_files))
    # Iterate. Some rewrites may expose others
    while any(x->x != -1, iteration_counter)
        # We need to redo the analysis after every fetmocleaning round, since
        # things may have changes as the result of an applied rewrite.
        analysis = Deprecations.process_all(filter(f->endswith(f, ".jl"), all_files))
        for (i, fpath) in enumerate(all_files)
            iteration_counter[i] == -1 && continue
            problematic_file = false
            file_analysis = endswith(fpath, ".jl") ? (analysis[1], analysis[2][fpath]) : nothing
            try
                if !Deprecations.edit_file(fpath, deps, endswith(fpath, ".jl") ? edit_text : edit_markdown;
                        analysis = file_analysis)
                    # Nothing to change
                    iteration_counter[i] = -1
                elseif iteration_counter[i] > max_iterations
                    warn("Iterations did not converge for file $fpath")
                    problematic_file = true
                else
                    iteration_counter[i] += 1
                    changed_any = true
                end
            catch e
                warn("Exception thrown when fixing file $fpath. Exception was:\n",
                     sprint(showerror, e, catch_backtrace()))
                problematic_file = true
            end
            if problematic_file
                push!(problematic_files, file)
                iteration_counter[i] = -1
            end
            changed_any && !problematic_file && LibGit2.add!(lrepo, relpath(fpath, local_dir))
        end
    end
    changed_any, problematic_files
end

function push_repo(api::GitHubWebAPI, repo, auth; force=true, remote_branch="fbot/deps")
    creds = LibGit2.UserPasswordCredentials(String(copy(Vector{UInt8}("x-access-token"))), String(copy(Vector{UInt8}(auth.token))))
    enabled = gc_enable(false)
    LibGit2.push(repo, refspecs = ["+HEAD:refs/heads/$remote_branch"], force=force,
        payload=Nullable(creds))
    gc_enable(enabled)
end

struct SourceFile
    data::Vector{UInt8}
    offsets::Vector{UInt64}
end
Base.length(file::SourceFile) = length(file.offsets)

function SourceFile(data)
    offsets = UInt64[0]
    buf = IOBuffer(data)
    local line = ""
    while !eof(buf)
        line = readuntil(buf,'\n')
        !eof(buf) && push!(offsets, position(buf))
    end
    if !isempty(line) && line[end] == '\n'
        push!(offsets, position(buf)+1)
    end
    SourceFile(data,offsets)
end

function compute_line(file::SourceFile, offset)
    ind = searchsortedfirst(file.offsets, offset)
    ind <= length(file.offsets) && file.offsets[ind] == offset ? ind : ind - 1
end

function Base.getindex(file::SourceFile, line::Int)
    if line == length(file.offsets)
        return file.data[(file.offsets[end]+1):end]
    else
        # - 1 to skip the '\n'
        return file.data[(file.offsets[line]+1):max(1, file.offsets[line+1]-1)]
    end
end
Base.getindex(file::SourceFile, arr::AbstractArray) = [file[x] for x in arr]

function repl_to_annotation(fpath, file, lrepo, local_dir, repo, repl)
    # Compute blob hash for fpath
    blob_hash = LibGit2.addblob!(lrepo, joinpath(local_dir, fpath))
    # Put together description
    start_line = compute_line(file, first(repl.range))
    message = """
        $(repl.dep === nothing ? "" : repl.dep.description)
        In file $fpath starting at line $(start_line):
            $(strip(String(file[start_line])))
    """
    Checks.Annotation(
        basename(fpath),
        "https://github.com/$(GitHub.name(repo))/blob/$(blob_hash)/$(fpath)",
        compute_line(file, first(repl.range)), compute_line(file, last(repl.range)),
        "notice",
        message,
        string(typeof(repl.dep).name.name)[1:min(end, 40)],
        ""
    )
end

function collect_deprecation_annotations(api::GitHubAPI, lrepo, local_dir, repo, auth; is_julia_itself=false)
    deps = deprecations_for_repo(lrepo, local_dir, is_julia_itself)
    annotations = Checks.Annotation[]
    problematic_files = String[]
    for (root, dirs, files) in walkdir(local_dir)
        for file in files
            fpath = joinpath(root, file)
            (endswith(fpath, ".jl") || endswith(fpath, ".md")) || continue
            file == "NEWS.md" && continue
            contents = readstring(fpath)
            sfile = SourceFile(contents)
            problematic_file = false
            try
                if endswith(fpath, ".md")
                    changed_any, _ = Deprecations.edit_markdown(contents, deps)
                    if changed_any
                        blob_hash = LibGit2.addblob!(lrepo, joinpath(local_dir, fpath))
                        push!(annotations, Checks.Annotation(
                            basename(fpath),
                            "https://github.com/$(GitHub.name(repo))/blob/$(blob_hash)/$(fpath)",
                            1, 1,
                            "notice",
                            """
                            Code changes were found in this Markdown document:
                            $(fpath)
                            """,
                            "MarkdownCode",
                            ""
                        ))
                    end
                else
                    repls = Deprecations.text_replacements(contents, deps)
                    for repl in repls
                        push!(annotations, repl_to_annotation(fpath, sfile, lrepo, local_dir, repo, repl))
                    end
                end
            catch e
                warn("Exception thrown when fixing file $file. Exception was:\n",
                     sprint(showerror, e, catch_backtrace()))
                problematic_file = true
            end
            problematic_file && push!(problematic_files, file)
        end
    end
    annotations, problematic_files
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

function cleanrepo(repo_url; show_diff = true, delete_local = true)
    local_dir = mktempdir()
    successful = true
    try
        enabled = gc_enable(false)
        info("Cloning $repo_url to $local_dir...")
        lrepo = LibGit2.clone(repo_url, local_dir)
        gc_enable(enabled)
        info("Processing deprecations...")
        changed_any, problematic_files = process_deprecations(lrepo, local_dir; is_julia_itself=contains(repo_url, "JuliaLang/julia"))
        isempty(problematic_files) || (successful = false)
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
        if delete_local
            info("Deleting cloned repo from $local_dir...")
            rm(local_dir, force=true, recursive=true)
        end
    end
    return successful
end

include("interactions.jl")
include("autodeployment.jl")

const autodeployment_enabled = haskey(ENV, "FEMTOCLEANER_AUTODEPLOY") ?
    ENV["FEMTOCLEANER_AUTODEPLOY"] == "yes" : false

let app_key = Ref{Any}(nothing)
    global get_auth
    function get_auth(app_id)
        if app_key[] == nothing
            app_key[] = MbedTLS.PKContext()
            MbedTLS.parse_key!(app_key[], haskey(ENV, "FEMTOCLEANER_PRIVKEY") ? ENV["FEMTOCLEANER_PRIVKEY"] : readstring(joinpath(dirname(@__FILE__),"..","privkey.pem")))
        end
        GitHub.JWTAuth(app_id, app_key[])
    end
end

function event_callback(api::GitHubAPI, app_name, app_id, sourcerepo_installation,
                        commit_sig, listener, bug_repository, event)
    # On installation, process every repository we just got installed into
    if event.kind == "installation"
        jwt = get_auth(app_id)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        for repo in event.payload["repositories"]
            repo = GitHub.repo(api, GitHub.Repo(repo); auth=auth)
            with_cloned_repo(api, repo, auth) do x
                apply_deprecations(api, x..., commit_sig, repo, auth)
            end
        end
    elseif event.kind == "check_run"
        jwt = get_auth(app_id)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        if event.payload["action"] == "requested_action" && event.payload["requested_action"]["identifier"] == "fix"
            repo = GitHub.Repo(event.payload["repository"])
            pr = PullRequest(event.payload["check_run"]["check_suite"]["pull_requests"][1])
            with_cloned_repo(api, repo, auth) do x
                lrepo, local_dir = x
                LibGit2.checkout!(lrepo, event.payload["check_run"]["check_suite"]["head_sha"])
                is_julia_itself = GitHub.name(repo) == "JuliaLang/julia"
                changed_any, problematic_files = process_deprecations(lrepo, local_dir; is_julia_itself=is_julia_itself)
                if changed_any
                    LibGit2.commit(lrepo, "Fix deprecations"; author=commit_sig, committer=commit_sig, parent_ids=[LibGit2.GitHash(lrepo, "HEAD")])
                    push_repo(api, lrepo, auth; force=false, remote_branch=event.payload["check_run"]["check_suite"]["head_branch"])
                end
            end
        end
    elseif event.kind == "pull_request"
        if !(event.payload["action"] in ("opened", "reopened", "synchronize"))
            return HTTP.Response(200)
        end
        jwt = get_auth(app_id)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        repo = Repo(event.payload["repository"])
        pr = PullRequest(event.payload["pull_request"])
        local annotations
        with_cloned_repo(api, repo, auth) do x
            lrepo, local_dir = x
            LibGit2.checkout!(lrepo, get(get(pr.head).sha))
            annotations, _ = collect_deprecation_annotations(api, x..., repo, auth)
        end
        actions = Checks.Action[]
        conclusion = "neutral"
        if length(annotations) == 0
            message = """
            No applicable deprecations were detected.
            """
            output = Checks.Output(
                "Femtocleaning",
                message,
                "",
                Checks.Annotation[],
                Checks.Image[]
            )
            conclusion = "success"
        else
            truncated = length(annotations) > 50
            message = """
            Several femtocleaning opportunities were detected
            """
            output = Checks.Output(
                "Femtocleaning",
                message,
                "See below",
                annotations[1:min(50, length(annotations))],
                GitHub.Image[]
            )
            actions = Checks.Action[
                Checks.Action(
                    "Fix it!",
                    "Fixes issues in this PR (adds commit).",
                    "fix"
                )
            ]
        end
        max_annotation = 50
        cr = GitHub.create_check_run(api, repo, auth=auth, params = Dict(
            :name => "femtocleaner",
            :head_branch => get(pr.head).ref,
            :head_sha => get(pr.head).sha,
            :status => "completed",
            :conclusion => conclusion,
            :completed_at => now(),
            :actions => actions,
            :output => output
        ))
        while max_annotation < length(annotations)
            empty!(output.annotations)
            append!(output.annotations, annotations[max_annotation+1:min(max_annotation+50, end)])
            max_annotation += 50
            GitHub.update_check_run(api, repo, get(cr.id), auth=auth, params = Dict(
                :output => output,
                :actions => actions
            ))
        end
    elseif event.kind == "installation_repositories"
        jwt = get_auth(app_id)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(api, installation, jwt)
        for repo in event.payload["repositories_added"]
            repo = GitHub.repo(api, GitHub.Repo(repo); auth=auth)
            with_cloned_repo(api, repo, auth) do x
                apply_deprecations(api, x..., commit_sig, repo, auth)
            end
        end
    elseif event.kind == "pull_request_review"
        jwt = get_auth(app_id)
        pr_response(api, event, jwt, commit_sig, app_name, sourcerepo_installation, bug_repository)
    elseif event.kind == "push"
        jwt = get_auth(app_id)
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
        jwt = get_auth(app_id)
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
    app_id = parse(Int, strip(haskey(ENV, "FEMTOCLEANER_APPID") ? ENV["FEMTOCLEANER_APPID"] : readstring(joinpath(dirname(@__FILE__),"..","app_id"))))
    secret = haskey(ENV, "FEMTOCLEANER_SECRET") ? ENV["FEMTOCLEANER_SECRET"] : nothing
    sourcerepo_installation = haskey(ENV, "FEMTOCLEANER_INSTALLATION") ? parse(Int, ENV["FEMTOCLEANER_INSTALLATION"]) : 0
    bug_repository = haskey(ENV, "FEMTOCLEANER_BUGREPO") ? ENV["FEMTOCLEANER_BUGREPO"] : ""
    (secret == nothing) && warn("Webhook secret not set. All events will be accepted. This is an insecure configuration!")
    jwt = get_auth(app_id)
    app_name = get(GitHub.app(; auth=jwt).name)
    commit_sig = LibGit2.Signature("$(app_name)[bot]", "$(app_name)[bot]@users.noreply.github.com")
    api = GitHub.DEFAULT_API
    local listener
    if nprocs() != 1
        #@everywhere filter(x->x != 1, procs()) worker_loop()
        for p in filter(x->x != 1, procs())
            @spawnat p begin
                myid() == 2 && update_existing_repos(api, commit_sig, app_id)
                worker_loop()
            end
        end
    end
    listener = GitHub.EventListener(secret=secret) do event
        queue() do
            revise()
            Base.invokelatest(event_callback, api, app_name, app_id,
                              sourcerepo_installation, commit_sig, listener, bug_repository, event)
        end
        HTTP.Response(200)
    end
    GitHub.run(listener, IPv4(0,0,0,0), 10000+app_id)
    wait()
end

end # module
