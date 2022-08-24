module GenerativePreTrain

using Flux
using Requires
using Requires: @init
using BSON

using ..Transformers: Abstract3DTensor
using ..Basic
using ..Pretrain: isbson, iszip, isnpbson, zipname, zipfile, findfile
export Gpt, load_gpt_pretrain, lmloss, GPTTextEncoder, GPT2TextEncoder

include("./gpt.jl")
include("./tokenizer.jl")
include("./textencoder.jl")
include("./npy2bson.jl")
include("./load_pretrain.jl")

end
