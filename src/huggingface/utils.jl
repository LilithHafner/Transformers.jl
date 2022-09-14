using JSON
using HuggingFaceApi: list_model_files

json_load(f) = Dict{Symbol, Any}(Symbol(k)=>v for (k, v) in JSON.parsefile(f))

_ensure(f::Function, A, args...; kwargs...) = isnothing(A) ? f(args...; kwargs...) : A

ensure_possible_files(possible_files, model_name; revision = nothing, auth_token = nothing, kw...) =
    _ensure(list_model_files, possible_files, model_name; revision, token = auth_token)

ensure_config(config, model_name; kw...) = _ensure(load_config, config, model_name; kw...)

load_error_msg(msg) = "$msg\nFile an issue with the model name you want to load."
load_error(msg) = error(load_error_msg(msg))
