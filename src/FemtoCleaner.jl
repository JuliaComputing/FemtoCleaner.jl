module FemtoCleaner

using GitHub
using HttpCommon
using Deprecations
using CSTParser
using Deprecations: isexpr
using Revise
using MbedTLS
using JSON
using AbstractTrees: children

function clone_and_process(local_dir, repo_url)
    lrepo = LibGit2.clone(repo_url, local_dir)
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
    lrepo, changed_any
end

function apply_deprecations(repo, auth)
    repo_url = "https://x-access-token:$(auth.token)@github.com/$(get(repo.full_name))"
    local_dir = mktempdir()
    try
        lrepo, changed_any = clone_and_process(local_dir, repo_url)
        if changed_any
            LibGit2.commit(lrepo, "Fix deprecations")
            LibGit2.push(lrepo, refspecs = ["+HEAD:refs/heads/fbot/deps"], force=true)
            create_pull_request(repo, auth=auth, params = Dict(
                    :title => "Fix deprecations",
                    :body => "I fixed a number of deprecations for you",
                    :base => get(repo.default_branch),
                    :head => "fbot/deps"
                )
            )
        else
            println("Processing complete: no changes made")
        end
    finally
        rm(local_dir, force=true, recursive=true)
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

function with_pr_branch(f, repo, auth)
    repo_url = "https://x-access-token:$(auth.token)@github.com/$(get(repo.full_name))"
    local_dir = mktempdir()
    try
        lrepo = LibGit2.clone(repo_url, local_dir)
        LibGit2.branch!(lrepo, "fbot/deps", track=LibGit2.Consts.REMOTE_ORIGIN)
        f((lrepo, local_dir))
    finally
        rm(local_dir, force=true, recursive=true)
    end
end

function byte_range_for_line(text, line)
    lines = split(text, '\n')
    first = sum(sizeof, lines[1:line-1]) + line
    first:(first+sizeof(lines[line])-1)
end

function first_expr_in_range(tree, range)
    for c in children(tree)
        first(range) in c.fullspan || continue
        first(c.span) in range && return c
        return first_expr_in_range(c, range)
    end
    error("No expression found in range")
end

function delete_expression_at_line(path, line)
    text = readstring(path)
    p = Deprecations.overlay_parse(text, true)
    @assert !isexpr(p, CSTParser.ERROR)
    range = byte_range_for_line(text, line)
    @show line
    @show range
    @show text[range]
    expr = first_expr_in_range(p, range - 1)
    open(path, "w") do f
        data = Vector{UInt8}(text)
        splice!(data, 1 + expr.fullspan)
        write(f, data)
    end
end

function respond(repo::Repo, rev::Review, c::Comment, auth)
    if get(c.body) == "delete this entirely"
        with_pr_branch(repo, auth) do x
            lrepo, local_dir = x
            diff_hunk = get(c.diff_hunk)
            # @@ -155,7 +155,7 @@
            buf = IOBuffer(diff_hunk)
            skip(buf, 2)
            readuntil(buf, '+')
            startline = parse(Int, readuntil(buf, ',')[1:end-1])
            path = joinpath(local_dir, get(c.path))
            # The comment occurs before get(c.position) so after
            # get(c.position)-1
            delete_expression_at_line(path, startline+get(c.position)-1)
            LibGit2.add!(lrepo, get(c.path))
            LibGit2.commit(lrepo, "Address review comments")
            LibGit2.push(lrepo, refspecs = ["HEAD:refs/heads/fbot/deps"])
        end
        return true
    else
        GitHub.reply_to(repo, rev, c, "I'm sorry, I don't know how to do that :anguished:."; auth = auth)
        return false
    end
end

function pr_response(event)
    # New review on a pull request
    #   Was this pull request opened by us
    pr = PullRequest(event.payload["pull_request"])
    get(get(pr.user).login) == "femtocleaner[bot]" || return
    #   Was the new review for changes requested?
    r = GitHub.Review(pr, event.payload["review"])
    get(r.state) == "changes_requested" || return
    # Authenticate
    jwt = GitHub.JWTAuth(4123, joinpath(Pkg.dir("FemtoCleaner"), "femtocleaner.2017-07-30.private-key.pem"))
    installation = Installation(event.payload["installation"])
    auth = create_access_token(installation, jwt)
    # Look through the comments for this review
    repo = Repo(event.payload["repository"])
    cs, page_data = comments(repo, r)
    results = map(c->respond(repo, r, c, auth), cs)
    while haskey(page_data, "next")
        cs, page_data = comments(r, start_page = page_data["next"])
        isempty(cs) && return
        append!(results, map(c->respond(repo, r, c, auth), cs))
    end
    if all(results)
        create_comment(repo, pr, "I have addressed the review comments."; auth=auth)
    elseif any(results)
        create_comment(repo, pr, "I have addressed all the review comments I know how to."; auth=auth)
    end
end

function event_callback(event)
    # On installation, process every repository we just got installed into
    if event.kind == "installation"
        jwt = GitHub.JWTAuth(4123, joinpath(Pkg.dir("FemtoCleaner"), "femtocleaner.2017-07-30.private-key.pem"))
        installation = Installation(event.payload["installation"])
        auth = create_access_token(installation, jwt)
        for repo in event.payload["repositories"]
            apply_deprecations(GitHub.repo(GitHub.Repo(repo)), auth)
        end
    elseif event.kind == "pull_request_review"
        pr_response(event)
    end
    return HttpCommon.Response(200)
end

function run_server()
    listener = GitHub.EventListener() do event
        revise()
        Base.invokelatest(event_callback, event)
    end
    GitHub.run(listener, host=IPv4(0,0,0,0), port=10423)
end

end # module
