using ..Layers
using ..Layers: CompositeEmbedding, SelfAttention
using Functors
using Static

using NeuralAttentionlib
using NeuralAttentionlib: WithScore, CausalMultiheadQKVAttenOp

abstract type HGFGPT2PreTrainedModel <: HGFPreTrainedModel end

struct HGFGPT2Model{E, DEC} <: HGFGPT2PreTrainedModel
    embed::E
    decoder::DEC
end
@functor HGFGPT2Model

(model::HGFGPT2Model)(nt::NamedTuple) = model.decoder(model.embed(nt))

struct HGFGPT2LMHeadModel{M, L} <: HGFGPT2PreTrainedModel
    model::M
    lm_head::L
end
@functor HGFGPT2LMHeadModel

(model::HGFGPT2LMHeadModel)(nt::NamedTuple) = model.lm_head(model.model(nt))

for T in :[
    HGFGPT2Model, HGFGPT2LMHeadModel
].args
    @eval function Base.show(io::IO, m::MIME"text/plain", x::$T)
        if get(io, :typeinfo, nothing) === nothing  # e.g. top level in REPL
            Flux._big_show(io, x)
        elseif !get(io, :compact, false)  # e.g. printed inside a Vector, but not a Matrix
            Flux._layer_show(io, x)
        else
            show(io, x)
        end
    end
end

basemodelkey(::Type{<:HGFGPT2PreTrainedModel}) = :transformer
isbasemodel(::Type{<:HGFGPT2Model}) = true
isbasemodel(::Type{<:HGFGPT2PreTrainedModel}) = false

get_model_type(::Val{:gpt2}) = (
  model = HGFGPT2Model,
  lmheadmodel = HGFGPT2LMHeadModel,
  # doubleheadsmodel = HGFGPT2DoubleHeadsModel,
)


function load_model(_type::Type{HGFGPT2Model}, cfg, state_dict = OrderedDict{String, Any}(), prefix = "")
    embed = load_model(_type, CompositeEmbedding, cfg, state_dict, prefix)
    decoder = load_model(_type, TransformerBlock, cfg, state_dict, prefix)
    return HGFGPT2Model(embed, decoder)
end

function load_model(_type::Type{HGFGPT2LMHeadModel}, cfg, state_dict = OrderedDict{String, Any}(), prefix = "")
    model = load_model(HGFGPT2Model, cfg, state_dict, joinname(prefix, "transformer"))
    if cfg[:tie_word_embeddings]
        embedding = model.embed.layer.token.embeddings
    else
        vocab_size, dims, factor = cfg[:vocab_size], cfg[:n_embd], Float32(cfg[:initializer_range])
        embedding = getweight(weight_init(vocab_size, dims, factor), Layers.Embed,
                              state_dict, joinname(prefix, "lm_head.weight"))
    end
    lmhead = Layers.EmbedDecoder(Layers.Embed(embedding))
    return HGFGPT2LMHeadModel(model, Layers.Branch{(:logit,), (:hidden_state,)}(lmhead))
end

function load_model(_type::Type{<:HGFGPT2PreTrainedModel}, ::Type{<:CompositeEmbedding}, cfg, state_dict, prefix)
    vocab_size, dims, max_pos = cfg[:vocab_size], cfg[:n_embd], cfg[:n_positions]
    factor = Float32(cfg[:initializer_range])
    token_weight = getweight(weight_init(vocab_size, dims, factor), Layers.Embed, state_dict, joinname(prefix, "wte.weight"))
    p = cfg[:embd_pdrop]; p = iszero(p) ? nothing : p
    pos_weight = getweight(weight_init(max_pos, dims, factor), Layers.Embed, state_dict, joinname(prefix, "wpe.weight"))
    embed = CompositeEmbedding(
        token = Layers.Embed(token_weight),
        position = Layers.FixedLenPositionEmbed(pos_weight)
    )
    return Layers.DropoutLayer(embed, p)
end

function load_model(_type::Type{<:HGFGPT2PreTrainedModel}, ::Type{<:Layers.LayerNorm}, cfg, state_dict, prefix)
    dims = cfg[:n_embd]
    ln_ϵ = Float32(cfg[:layer_norm_epsilon])
    old_weight_name = joinname(prefix, "gamma")
    old_bias_name = joinname(prefix, "beta")
    weight_name = haskey(state_dict, old_weight_name) ? old_weight_name : joinname(prefix, "weight")
    bias_name = haskey(state_dict, old_bias_name) ? old_bias_name : joinname(prefix, "bias")
    ln_weight = getweight(() -> ones(Float32, dims), Array, state_dict, weight_name)
    ln_bias = getweight(() -> zeros(Float32, dims), Array, state_dict, bias_name)
    return Layers.LayerNorm(ln_weight, ln_bias, ln_ϵ)
end

function load_model(_type::Type{<:HGFGPT2PreTrainedModel}, ::Type{<:SelfAttention}, cfg, state_dict, prefix)
    head, dims = cfg[:n_head], cfg[:n_embd]
    @assert dims % head == 0 "The hidden size is not a multiple of the number of attention heads."
    p = cfg[:attn_pdrop]; p = iszero(p) ? nothing : p
    return_score = cfg[:output_attentions]
    factor = Float32(cfg[:initializer_range])
    # TODO: cfg[:scale_attn_weights]
    attn_weight = getweight(weight_init(dims, 3dims, factor), Layers.Embed, state_dict, joinname(prefix, "c_attn.weight"))
    attn_bias = getweight(zero_init(3dims), Array, state_dict, joinname(prefix, "c_attn.bias"))
    qkv_proj = Layers.NSplit(static(3), Layers.Dense(attn_weight, attn_bias))
    o_weight = getweight(weight_init(dims, dims, factor), Layers.Embed, state_dict, joinname(prefix, "c_proj.weight"))
    o_bias = getweight(zero_init(dims), Array, state_dict, joinname(prefix, "c_proj.bias"))
    o_proj = Layers.Dense(o_weight, o_bias)
    op = CausalMultiheadQKVAttenOp(head, p)
    return_score && (op = WithScore(op))
    return SelfAttention(op, qkv_proj, o_proj)
end

function load_model(
    _type::Type{<:HGFGPT2PreTrainedModel}, ::Type{<:Layers.Chain{<:Tuple{Layers.Dense, Layers.Dense}}},
    cfg, state_dict, prefix
)
    dims = cfg[:n_embd]
    ff_dims = get(cfg, :n_inner, nothing)
    ff_dims = isnothing(ff_dims) ? 4dims : ff_dims
    factor = Float32(cfg[:initializer_range])
    act = ACT2FN[Symbol(cfg[:activation_function])]
    wi_weight = getweight(weight_init(dims, ff_dims, factor), Layers.Embed,
                          state_dict, joinname(prefix, "c_fc.weight"))
    wi_bias = getweight(zero_init(ff_dims), Array, state_dict, joinname(prefix, "c_fc.bias"))
    wo_weight = getweight(weight_init(ff_dims, dims, factor), Layers.Embed,
                          state_dict, joinname(prefix, "c_proj.weight"))
    wo_bias = getweight(zero_init(dims), Array, state_dict, joinname(prefix, "c_proj.bias"))
    return Layers.Chain(Layers.Dense(act, wi_weight, wi_bias), Layers.Dense(wo_weight, wo_bias))
end

function load_model(_type::Type{<:HGFGPT2PreTrainedModel}, ::Type{<:TransformerBlock}, cfg, state_dict, prefix)
    n = cfg[:n_layer]
    p = cfg[:resid_pdrop]; p = iszero(p) ? nothing : p
    collect_output = cfg[:output_attentions] || cfg[:output_hidden_states]
    blocks = []
    for i = 1:n
        lprefix = joinname(prefix, :h, i-1)
        sa = load_model(_type, SelfAttention, cfg, state_dict, joinname(lprefix, "attn"))
        sa_ln = load_model(_type, Layers.LayerNorm, cfg, state_dict, joinname(lprefix, "ln_1"))
        sa = Layers.PreNormResidual(Layers.DropoutLayer(sa, p), sa_ln)
        ff = load_model(_type, Layers.Chain{Tuple{Layers.Dense, Layers.Dense}}, cfg, state_dict, joinname(lprefix, "mlp"))
        ff_ln = load_model(_type, Layers.LayerNorm, cfg, state_dict, joinname(lprefix, "ln_2"))
        ff = Layers.PreNormResidual(Layers.DropoutLayer(ff, p), ff_ln)
        block = TransformerBlock(sa, ff)
        push!(blocks, block)
    end
    collect_f = collect_output ? Layers.collect_outputs : nothing
    trf = Transformer(Tuple(blocks), collect_f)
    final_ln = load_model(_type, Layers.LayerNorm, cfg, state_dict, joinname(prefix, "ln_f"))
    return Layers.Chain(trf, final_ln)
end
