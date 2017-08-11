using FemtoCleaner
using Base.Test
using GitHub
using GitHub: WebhookEvent, GitHubAPI

struct FemtoCleanerTestAPI <: GitHubAPI; end
GitHub.create_access_token(api::FemtoCleanerTestAPI, installation, jwt) = GitHub.OAuth2("BadData")
GitHub.repo(api::FemtoCleanerTestAPI, r) = r

function setup_local_dir(local_dir)
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
end

function FemtoCleaner.with_cloned_repo(f, api::FemtoCleanerTestAPI, repo, auth)
    local_dir = mktempdir()
    try
        lrepo = LibGit2.init(local_dir)
        setup_local_dir(local_dir)
        f((lrepo, local_dir))
        close(lrepo)
    finally
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