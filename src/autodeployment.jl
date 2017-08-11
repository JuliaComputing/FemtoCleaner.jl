using Base: LibGit2

function has_open_femtocleaner_pr(api, repo, auth)
    prs, page_data = pull_requests(api, repo; params = Dict(
        :state => "open",
        :head => "fbot/deps"
    ), auth=auth)
    !isempty(prs)
end

function update_repo(api, repo, auth, commit_sig)
    with_cloned_repo(api, repo, auth) do x
        lrepo, local_dir = x
        changed_any = process_deprecations(lrepo, local_dir)
        if !changed_any
            # Close the PR
            println("No changes left in $(GitHub.name(repo))")
        else
            # Diff the new changes against what's already in the PR
            lcommit = LibGit2.GitCommit(lrepo, LibGit2.commit(lrepo, "Fix deprecations"; author=commit_sig, committer=commit_sig))
            rbranch = LibGit2.revparse(lrepo, "refs/remotes/origin/fbot/deps")
            diff = LibGit2.diff_tree(lrepo, LibGit2.peel(lcommit), LibGit2.peel(rbranch))
            if count(diff) == 0
                println("No difference in new patch for $(GitHub.name(repo))")
            else
                println("Should update $(GitHub.name(repo))*")
            end
        end
    end
end

function update_existing_repos(api, commit_sig, jwt)
    for inst in installations(api, jwt)
        repos_with_open_prs = Repo[]
        auth = create_access_token(api, inst, jwt)
        irepos, page_data = repos(api, inst; auth=auth)
        has_open_prs(repo) = has_open_femtocleaner_pr(api, repo, auth)
        append!(repos_with_open_prs, filter(has_open_prs, irepos))
        while haskey(page_data, "next")
            irepos, page_data = repos(api, inst; auth=auth, start_page = page_data["next"])
            append!(repos_with_open_prs, filter(has_open_prs, irepos))
        end
        foreach(repos_with_open_prs) do repo
            update_repo(api, repo, auth, commit_sig)
        end
    end
end

function maybe_autdodeploy(event, listener, jwt, sourcerepo_installation, enabled)
    @assert event.kind == "push"
    repo = Repo(event.payload["repository"])
    (GitHub.name(repo) == "Keno/FemtoCleaner.jl") || return
    (event.payload["ref"] == "refs/heads/master") || return
    if !enabled
        warn("Push event received, but auto deployment is disabled")
        return
    end
    info("Commencing auto deployment")
    with(GitRepo, Pkg.dir("FemtoCleaner")) do repo
        LibGit2.fetch(repo)
        ahead_remote, ahead_local = LibGit2.revcount(repo, "origin/master", "master")
        rcount = min(ahead_remote, ahead_local)
        if ahead_local-rcount > 0
            warn("Local repository has more commits that origin. Aborting")
            return false
        end
        # Shut down the server, so the new process can replace it
        close(listener.server)
        LibGit2.reset!(repo, LibGit2.GitHash(event.payload["after"]), LibGit2.Consts.RESET_HARD)
        for (pkg, version) in JSON.parse(readstring(joinpath(dirname(@__FILE__),"..","dependencies.json")))
            with(GitRepo, Pkg.dir(pkg)) do deprepo
                for remote in LibGit2.remotes(deprepo)
                    LibGit2.fetch(deprepo; remote=remote)
                end
                LibGit2.reset!(deprepo, LibGit2.GitHash(version), LibGit2.Consts.RESET_HARD)
            end
        end
        if sourcerepo_installation != 0
            auth = create_access_token(Installation(sourcerepo_installation), jwt)
            create_comment(Repo("Keno/FemtoCleaner.jl"), event.payload["after"], :commit; auth=auth,
                params = Dict(
                    :body => "I have deployed this commit :shipit:."
                )
            )
        end
        @async begin
            run(`$(Base.julia_cmd()) --history-file=no -e 'using FemtoCleaner; FemtoCleaner.run_server()'`)
            println("Dead")
            sleep(10)
            exit()
        end
    end
end
