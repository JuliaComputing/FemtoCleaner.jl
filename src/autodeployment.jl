using Base: LibGit2

function maybe_autdodeploy(event, listener, enabled)
    @assert event.kind == "push"
    repo = Repo(event.payload["repository"])
    (name(repo) == "Keno/FemtoCleaner.jl") || return
    (event.payload["repository"]["ref"] == "refs/heads/master") || return
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
        close(listener)
        LibGit2.reset!(repo, event.payload["after"], Consts.RESET_HARD)
        run(`$(Base.julia_cmd()) --history-file=no -e 'using FemtoCleaner; FemtoCleaner.run_server()'`)
        exit()
    end
end
