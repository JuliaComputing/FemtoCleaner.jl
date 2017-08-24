using GitHub
using JLD2

function femtocleaner_prs(api, repo, auth)
    prs, _ = pull_requests(api, repo; params = Dict(
        :state => "all",
        :head => "$(GitHub.name(get(repo.owner))):fbot/deps"
    ), auth=auth)
    prs
end

function collect_statistics(app_id, key_path)
    println("# FemtoCleaner statistics at $(now())")
    jwt = GitHub.JWTAuth(app_id, key_path)
    app_name = get(GitHub.app(; auth=jwt).name)
    insts, _ = installations(jwt)
    api = GitHub.DEFAULT_API
    println("FemtoCleaner is installed in $(length(insts)) accounts:")
    for inst in insts
        println("\t", GitHub.name(get(inst.account)))
    end
    all_prs = Any[]
    all_repos = Any[]
    nrepos = 0
    ntotal_prs = 0
    ntotal_additions = 0
    ntotal_deletions = 0
    for inst in insts
        auth = create_access_token(api, inst, GitHub.JWTAuth(app_id, key_path))
        irepos, _ = repos(api, inst; auth=auth)
        foreach(irepos) do repo
            nrepos += 1
            println("Processing $(GitHub.name(repo))")
            reqs = try
                req_file = GitHub.file(repo, "REQUIRE"; auth=auth)
                Pkg.Reqs.parse(IOBuffer(base64decode(strip(get(req_file.content)))))
            catch e
                @show e
                nothing
            end
            push!(all_repos, (repo, reqs))
            prs = femtocleaner_prs(api, repo, auth)
            prs = map(pr->GitHub.pull_request(repo, pr; auth=auth), prs)
            append!(all_prs, Iterators.product((repo,),prs))
            ntotal_prs += length(prs)
            isempty(prs) && return
            ntotal_additions += sum(pr->get(pr.additions), prs)
            ntotal_deletions += sum(pr->get(pr.deletions), prs)
        end
    end
    println("Opened $ntotal_prs PRs in $nrepos repositories (+$ntotal_additions -$ntotal_deletions)")
    @save "data.jld2" all_repos all_prs
end