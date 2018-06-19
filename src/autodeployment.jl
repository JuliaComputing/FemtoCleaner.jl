using Base: LibGit2

function femtocleaner_prs(api, repo, auth)
    prs, _ = pull_requests(api, repo; params = Dict(
        :state => "open",
        :head => "$(GitHub.name(get(repo.owner))):fbot/deps"
    ), auth=auth)
    prs
end

function update_repo(api, repo, auth, commit_sig)
    with_cloned_repo(api, repo, auth) do x
        lrepo, local_dir = x
        is_julia_itself = GitHub.name(repo) == "JuliaLang/julia"
        changed_any, problematic_files = process_deprecations(lrepo, local_dir; is_julia_itself=is_julia_itself)
        if !changed_any
            # Close the PR
            pr = first(femtocleaner_prs(api, repo, auth))
            close_pull_request(api, repo, pr; auth=auth)
            create_comment(api, repo, pr, """
            My code has been updated and now I don't think there's anything to do here anymore.
            Maybe you changed the code, or maybe it's me. Either way, I'll see you next time.
            """; auth=auth)
            println("No changes left in $(GitHub.name(repo))")
        else
            # Diff the new changes against what's already in the PR
            lcommit = LibGit2.GitCommit(lrepo, LibGit2.commit(lrepo, "Fix deprecations"; author=commit_sig, committer=commit_sig, parent_ids=[LibGit2.GitHash(lrepo, "HEAD")]))
            rbranch = LibGit2.GitObject(lrepo, "refs/remotes/origin/fbot/deps")
            diff = LibGit2.diff_tree(lrepo, LibGit2.peel(lcommit), LibGit2.peel(rbranch))
            if count(diff) == 0
                println("No difference in new patch for $(GitHub.name(repo))")
            else
                println("Should update $(GitHub.name(repo))")
                pr = first(femtocleaner_prs(api, repo, auth))
                push_repo(api, lrepo, auth)
                create_comment(api, repo, pr, """
                My code has been updated. I now view the world differently.
                Am I still the same bot I was before?
                In any case, I've updated this PR to reflect my new knowledge. I hope you like it.
                """; auth=auth)
            end
        end
    end
end

function update_existing_repos(api, commit_sig, app_id)
    for inst in installations(api, get_auth(app_id))[1]
        try
            repos_with_open_prs = Repo[]
            auth = create_access_token(api, inst, get_auth(app_id))
            irepos, _ = repos(api, inst; auth=auth)
            has_open_prs(repo) = !isempty(femtocleaner_prs(api, repo, auth))
            append!(repos_with_open_prs, filter(has_open_prs, irepos))
            foreach(repos_with_open_prs) do repo
                update_repo(api, repo, auth, commit_sig)
            end
        catch e
            bt = catch_backtrace()
            Base.display_error(STDERR, e, bt)
        end
    end
end

function maybe_autdodeploy(event, listener, jwt, sourcerepo_installation, enabled)
    @assert event.kind == "push"
    repo = Repo(event.payload["repository"])
    (GitHub.name(repo) == "JuliaComputing/FemtoCleaner.jl") || return
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
            create_comment(Repo("JuliaComputing/FemtoCleaner.jl"), event.payload["after"], :commit; auth=auth,
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
