using FemtoCleaner
using Base.Test
using GitHub
using GitHub: WebhookEvent, GitHubAPI

struct FemtoCleanerTestAPI <: GitHubAPI; end
GitHub.create_access_token(api::FemtoCleanerTestAPI, installation::Installation, jwt::GitHub.JWTAuth) = GitHub.OAuth2("BadData")
GitHub.repo(api::FemtoCleanerTestAPI, r) = r

function setup_local_dir(repo, local_dir)
    mkdir(joinpath(local_dir, "src"))
    open(joinpath(local_dir, "REQUIRE"), "w") do f
        println(f, "julia 0.6")
    end
    open(joinpath(local_dir, "src", "test.jl"), "w") do f
        println(f, """
        module DeprecationBotTest

            function foobar{T}(x, y::T)
                println(x, y)
            end

        end
        """)
    end
    LibGit2.add!(repo, "REQUIRE")
    LibGit2.add!(repo, "src/test.jl")
    LibGit2.commit(repo, "Initial commit")
    LibGit2.branch!(repo, "fbot/deps")
    open(joinpath(local_dir, "src", "test.jl"), "w") do f
        println(f, """
        module DeprecationBotTest

            function foobar(x, y::T) where T
                println(x, y)
            end

        end
        """)
    end
    LibGit2.add!(repo, "src/test.jl")
    LibGit2.commit(repo, "Initial deprecation fix")
    LibGit2.head!(repo, get(LibGit2.lookup_branch(repo, "master")))
end

function FemtoCleaner.with_cloned_repo(f, api::FemtoCleanerTestAPI, repo, auth)
    local_remote_dir = mktempdir()
    local_dir = mktempdir()
    try
        lrrepo = LibGit2.init(local_remote_dir)
        setup_local_dir(lrrepo, local_remote_dir)
        close(lrrepo)
        lrepo = LibGit2.clone("file://$local_remote_dir", local_dir)
        LibGit2.head!(lrepo, get(LibGit2.lookup_branch(lrepo, "master")))
        f((lrepo, local_dir))
        close(lrepo)
    finally
        rm(local_remote_dir, force=true, recursive=true)
        rm(local_dir, force=true, recursive=true)
    end
end

# Actions
actions = Any[]
function FemtoCleaner.push_repo(api::FemtoCleanerTestAPI, repo)
    push!(actions, :push)
end
function GitHub.create_pull_request(api::FemtoCleanerTestAPI, args...; kwargs...)
    push!(actions, :pr)
end

fake_app_key = MbedTLS.PKContext()
MbedTLS.parse_key!(fake_app_key, readstring(
    joinpath(Pkg.dir("GitHub","test"), "not_a_real_key.pem")))
app_name = "femtocleaner-test"
test_commit_sig = LibGit2.Signature("$(app_name)[bot]", "$(app_name)[bot]@users.noreply.github.com")

test_event(event) = FemtoCleaner.event_callback(FemtoCleanerTestAPI(), app_name,
    fake_app_key, 1, 1, test_commit_sig, nothing, "Keno/FemtoCleanerBugs", event)

# Check that it opens a PR on installation
test_event(WebhookEvent(
    "installation",
    JSON.parse("""
        {
            "installation": {
                "id": 1
            },
            "repositories": [
                {
                    "id": 1,
                    "full_name": "Keno/TestRepo",
                    "default_branch": "foo/branch"
                }
            ]
        }
    """), Repo(""), Owner("")
))
@test actions == [:push, :pr]

# Check that it opens a PR when a repo is added
empty!(actions)
test_event(WebhookEvent(
    "installation_repositories",
    JSON.parse("""
        {
            "installation": {
                "id": 1
            },
            "repositories_added": [
                {
                    "id": 1,
                    "full_name": "Keno/TestRepo",
                    "default_branch": "foo/branch"
                }
            ]
        }
    """), Repo(""), Owner("")
))
@test actions == [:push, :pr]

# Smoke test for the startup upgrade
GitHub.installations(api::FemtoCleanerTestAPI, jwt::GitHub.JWTAuth) = map(Installation, [1, 2])
function GitHub.repos(api::FemtoCleanerTestAPI, i::GitHub.Installation; kwargs...)
    if get(i.id) == 1
        repos = map(Repo, ["Keno/A", "Keno/B"])
    elseif get(i.id) == 2
        repos = map(Repo, ["Keno/C"])
    else
        error()
    end
    foreach(repos) do repo
        repo.owner = Owner("Keno")
    end
    repos, Dict()
end
function GitHub.pull_requests(api::FemtoCleanerTestAPI, r::GitHub.Repo; kwargs...)
    if GitHub.name(r) == "Keno/A"
        [map(PullRequest, [1])], Dict()
    else
        PullRequest[], Dict()
    end
end

FemtoCleaner.update_existing_repos(FemtoCleanerTestAPI(), test_commit_sig, 1, fake_app_key)