using ArgParse
using Transformers

ENV["DATADEPS_ALWAYS_ACCEPT"] = true

function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        "--gpu", "-g"
            help = "use gpu"
            action = :store_true
        "task"
            help = "task name"
            required = true
            range_tester = x-> x ∈ ["cola", "mnli", "mrpc", "hgf_cola"]
    end

    return parse_args(ARGS, s)
end

const args = parse_commandline()

enable_gpu(args["gpu"])

const task = args["task"]

include(joinpath(@__DIR__, task, "train.jl"))
