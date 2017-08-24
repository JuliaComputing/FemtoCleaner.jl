using Deprecations: apply_formatter, changed_text, TextReplacement

struct FileTextReplacement
    path::String
    repl::TextReplacement
end
FileTextReplacement(path::String, args...) = FileTextReplacement(path, TextReplacement(args...))

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

function with_node_at_line(f, path, line)
    text = readstring(path)
    p = Deprecations.overlay_parse(text, true)
    @assert !isexpr(p, CSTParser.ERROR)
    range = byte_range_for_line(text, line)
    expr = first_expr_in_range(p, range - 1)
    f(expr)
end

function delete_expression_at_line(path, line)
    with_node_at_line(path, line) do expr
        FileTextReplacement(path, expr.fullspan, "")
    end
end

function align_arguments(path, line)
    with_node_at_line(path, line) do expr
        FileTextReplacement(path,
            apply_formatter(Deprecations.format_align_arguments, expr))
    end
end

function file_bugreport(api::GitHubAPI, sender, pr, repo, bug_reports, bug_repository, repo_auth)
    body = """
    @$(GitHub.name(sender)) has indicated an incorrect bot action in https://github.com/$(GitHub.name(repo))/pull/$(get(pr.number))
    The relevant snippets are shown below:
    """
    for c in bug_reports
        body *= "\n```diff\n$(get(c.diff_hunk))\n```"
    end
    GitHub.create_issue(api, Repo(bug_repository); auth=repo_auth, params = Dict(
        :body => body,
        :title => "Incorrect bot action in $(GitHub.name(repo))"
    ))
end

function respond(api, repo::Repo, rev::Review, c::Comment, auth, actions, bug_reports)
    # Figure out what line we're at
    line = begin
        diff_hunk = get(c.diff_hunk)
        buf = IOBuffer(diff_hunk)
        skip(buf, 2)
        readuntil(buf, '+')
        @show c
        println(diff_hunk)
        startline = parse(Int, readuntil(buf, ',')[1:end-1])
        startline + count(c->c[1] == ' ' || c[1] == '+',
            split(diff_hunk, '\n')[2:end]) - 1
    end
    @show line
    if get(c.body) == "delete this entirely"
        push!(actions, (local_dir, resolutions)->begin
            path = joinpath(local_dir, get(c.path))
            push!(resolutions, delete_expression_at_line(path, line))
        end)
        return true
    elseif get(c.body) == "align arguments"
        push!(actions, (local_dir, resolutions)->begin
            path = joinpath(local_dir, get(c.path))
            push!(resolutions, align_arguments(path, line))
        end)
        return true
    elseif get(c.body) == "bad bot"
        push!(bug_reports, c)
        GitHub.reply_to(api, repo, rev, c, "I'm sorry. I'm still new at this :monkey:. I'll file an issue about this for you."; auth = auth)
        return false
    else
        GitHub.reply_to(api, repo, rev, c, "I'm sorry, I don't know how to do that :anguished:."; auth = auth)
        return false
    end
end

function pr_response(api, event, jwt, commit_sig, app_name, sourcerepo_installation, bug_repository)
    # Was this a Review submission?
    (event.payload["action"] == "submitted") || return
    #   Was this pull request opened by us
    pr = PullRequest(event.payload["pull_request"])
    get(get(pr.user).login) == "$(app_name)[bot]" || return
    #   Was the new review for changes requested?
    r = GitHub.Review(pr, event.payload["review"])
    get(r.state) == "changes_requested" || return
    # Authenticate
    installation = Installation(event.payload["installation"])
    auth = create_access_token(api, installation, jwt)
    # Look through the comments for this review
    repo = Repo(event.payload["repository"])
    cs, page_data = comments(api, repo, r)
    @show length(cs)
    actions = Any[]
    bug_reports = Any[]
    results = map(c->respond(api, repo, r, c, auth, actions, bug_reports), cs)
    while haskey(page_data, "next")
        cs, page_data = comments(api, repo, r, start_page = page_data["next"])
        isempty(cs) && return
        append!(results, map(c->respond(api, repo, r, c, auth, actions, bug_reports), cs))
    end
    if !isempty(bug_reports) && !isempty(bug_repository)
        repo_auth = create_access_token(api, Installation(sourcerepo_installation), jwt)
        file_bugreport(api, get(r.user), pr, repo, bug_reports, bug_repository, repo_auth)
    end
    resolutions = Any[]
    if !isempty(actions)
        with_pr_branch(api, repo, auth) do x
            lrepo, local_dir = x
            for a in actions
                a(local_dir, resolutions)
            end
            paths = unique(map(r->r.path, resolutions))
            for path in paths
                text = readstring(joinpath(local_dir, path))
                open(joinpath(local_dir, path), "w") do f
                    changes = collect(map(x->x.repl,
                        filter(x->x.path == path, resolutions)))
                    @show (path, changes)
                    write(f, changed_text(text, changes)[2])
                end
                LibGit2.add!(lrepo, relpath(path, local_dir))
            end
            LibGit2.commit(lrepo, "Address review comments"; author=commit_sig, committer=commit_sig, parent_ids=[LibGit2.GitHash(lrepo, "HEAD")])
            push_repo(api, lrepo, auth; force = false)
        end
    end
    if all(results)
        create_comment(api, repo, pr, "I have addressed the review comments."; auth=auth)
    elseif any(results)
        create_comment(api, repo, pr, "I have addressed all the review comments I know how to."; auth=auth)
    end
end
