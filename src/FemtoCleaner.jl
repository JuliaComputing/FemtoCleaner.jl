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

const commit_sig = LibGit2.Signature("femtocleaner[bot]", "femtocleaner[bot]@users.noreply.github.com")

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
            LibGit2.commit(lrepo, "Fix deprecations"; author=commit_sig, committer=commit_sig)
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

include("interactions.jl")

app_key = MbedTLS.PKContext()
MbedTLS.parse_key!(app_key, ENV["FEMTOCLEANER_PRIVKEY"])

function event_callback(app_key, event)
    # On installation, process every repository we just got installed into
    if event.kind == "installation"
        jwt = GitHub.JWTAuth(4123, app_key)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(installation, jwt)
        for repo in event.payload["repositories"]
            apply_deprecations(GitHub.repo(GitHub.Repo(repo)), auth)
        end
    elseif event.kind == "installation_repositories"
        jwt = GitHub.JWTAuth(4123, app_key)
        installation = Installation(event.payload["installation"])
        auth = create_access_token(installation, jwt)
        for repo in event.payload["repositories_added"]
            apply_deprecations(GitHub.repo(GitHub.Repo(repo)), auth)
        end
    elseif event.kind == "pull_request_review"
        pr_response(event)
    end
    return HttpCommon.Response(200)
end

function run_server()
    app_key = MbedTLS.PKContext()
    MbedTLS.parse_key!(app_key, ENV["FEMTOCLEANER_PRIVKEY"])
    listener = GitHub.EventListener() do event
        revise()
        Base.invokelatest(event_callback, app_key, event)
    end
    GitHub.run(listener, host=IPv4(0,0,0,0), port=10423)
end

end # module
