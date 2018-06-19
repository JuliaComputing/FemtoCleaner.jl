const idle_workers = Int[]
const workqueue = Channel(Inf)

function worker_loop()
    try
        while true
            id = myid()
            fetch(@spawnat 1 begin
                item = take!(FemtoCleaner.workqueue)
                println("Beginning work on worker ", id)
                item
            end)()
        end
    catch e
        bt = catch_backtrace()
        Base.showerror(STDERR, e, bt)
    end
end

queue(work) = nprocs() == 1 ? work() : push!(workqueue, work)
