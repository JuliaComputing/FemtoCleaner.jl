using Base: LibGit2

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
