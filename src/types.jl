module Types

export typeid, ztype, juliatype, ZType

abstract type ZType end

abstract type Primitive <: ZType end

abstract type Number <: Primitive end
abstract type Integer <: Number end
abstract type Signed <: Integer end
abstract type Float <: Number end

# by default, types store their id
# primitive types overload directly
typeid(x) = x.id
ztype(id) = ZTYPE_PRIMITIVES[id]
juliatype(f, type::T) where {T <: ZType} = f(juliatype(type))

const ZTYPE_PRIMITIVES = Dict{Int, ZType}()

struct NotImplemented end

for (i, T, ST, JT) in (
        (0, :Uint8, :Integer, Base.UInt8),
        (1, :Uint16, :Integer, Base.UInt16),
        (2, :Uint32, :Integer, Base.UInt32),
        (3, :Uint64, :Integer, Base.UInt64),
        (4, :Uint128, :Integer, Base.UInt128),
        (5, :Uint256, :Integer, NotImplemented),
        (6, :Int8, :Signed, Base.Int8),
        (7, :Int16, :Signed, Base.Int16),
        (8, :Int32, :Signed, Base.Int32),
        (9, :Int64, :Signed, Base.Int64),
        (10, :Int128, :Signed, Base.Int128),
        (11, :Int256, :Signed, NotImplemented),
        (12, :Duration, :Signed, NotImplemented),
        (13, :Time, :Signed, NotImplemented),
        (14, :Float16, :Float, Base.Float16),
        (15, :Float32, :Float, Base.Float32),
        (16, :Float64, :Float, Base.Float64),
        (17, :Float128, :Float, NotImplemented),
        (18, :Float256, :Float, NotImplemented),
        (19, :Decimal32, :Number, NotImplemented),
        (20, :Decimal64, :Number, NotImplemented),
        (21, :Decimal128, :Number, NotImplemented),
        (22, :Decimal256, :Number, NotImplemented),
        (23, :Bool, :Primitive, Base.Bool),
        (24, :Bytes, :Primitive, Vector{UInt8}),
        (25, :String, :Primitive, Base.String),
        (26, :IP, :Primitive, Base.String),
        (27, :Net, :Primitive, Base.String),
        (28, :TypeZ, :Primitive, Base.String),
        (29, :Null, :Primitive, Nothing),
        (30, :TypeComplex, :Primitive, NotImplemented),
    )
    nm = Symbol(T, "Type")
    @eval begin
        struct $nm <: $ST end
        const $T = $nm()
        typeid(::$nm) = $i
        ZTYPE_PRIMITIVES[$i] = $T
        juliatype(::$nm) = $JT
    end
end

end # module Types

using .Types

struct TypeNamed <: ZType
    id::Int
    name::String
    type::ZType
end

struct TypeContext
    lock::ReentrantLock
    byID::Vector{ZType}
    toType::Dict{Vector{UInt8}, ZType}
    toValue::Dict{ZType, Vector{UInt8}}
    typedefs::Dict{Vector{UInt8}, TypeNamed}
    # stringErr *TypeError
    # missing   *Value
    # quiet     *Value
end

TypeContext() = TypeContext(ReentrantLock(), Vector{ZType}(undef, typeid(Types.TypeComplex) - 1), Dict{String, ZType}(), Dict{ZType, String}(), Dict{String, TypeNamed}())
# MUST be called while holding lock
nextid(ctx) = length(ctx.byID) + 1

# MUST be called while holding lock
function add!(c, tbytes, type::ZType)
    tv = copy(tbytes)
    c.toValue[type] = tv
    c.toType[tv] = type
    push!(c.byID, type)
    return
end

function add!(f::Function, ctx, buf, startpos, pos)
    tbytes = view(buf, startpos:(pos - 1))
    Base.@lock ctx.lock begin
        if !haskey(ctx.toType, tbytes)
            # we haven't seen this type before
            id = nextid(ctx)
            add!(ctx, tbytes, f(id))
        end
    end
end

function Types.ztype(ctx::TypeContext, id::Integer)
    if id < typeid(Types.TypeComplex)
        # primitive type
        return Types.ztype(id)
    end
    Base.@lock ctx.lock begin
        return ctx.byID[id]
    end
end

struct Field
    name::String
    type::ZType
end

struct TypeRecord <: ZType
    id::Int
    fields::Vector{Field}
    lu::Dict{String, Int} # field name => field index
end

TypeRecord(id, fields) = TypeRecord(id, fields, Dict(c.name => i for (i, c) in enumerate(fields)))

Types.juliatype(T::TypeRecord) = NamedTuple{Tuple(Symbol(f.name) for f in T.fields), Tuple{(juliatype(f.type) for f in T.fields)...}}

struct TypeArray <: ZType
    id::Int
    type::ZType
end

Types.juliatype(T::TypeArray) = Vector{juliatype(T.type)}

struct TypeError <: ZType
    id::Int
    type::ZType
end

struct Error{T} <: Exception
    value::T
end

Types.juliatype(T::TypeError) = Error{juliatype(T.type)}

struct TypeEnum <: ZType
    id::Int
    symbols::Vector{String}
end

Types.juliatype(T::TypeEnum) = Symbol

struct TypeMap <: ZType
    id::Int
    keytype::ZType
    valtype::ZType
end

Types.juliatype(T::TypeMap) = Dict{juliatype(T.keytype), juliatype(T.valtype)}

struct TypeNamed <: ZType
    id::Int
    name::String
    type::ZType
end

Types.juliatype(T::TypeNamed) = juliatype(T.type)

struct TypeSet <: ZType
    id::Int
    type::ZType
end

Types.juliatype(T::TypeSet) = Set{juliatype(T.type)}

struct TypeUnion <: ZType
    id::Int
    types::Vector{ZType}
    lu::Dict{ZType, Int}
end

TypeUnion(id::Int, types::Vector{ZType}) = TypeUnion(id, types, Dict(typ => i for (i, typ) in enumerate(types)))

Types.juliatype(T::TypeUnion) = Union{map(juliatype, T.types)...}

const TypeDefRecord = 0
const TypeDefArray  = 1
const TypeDefSet    = 2
const TypeDefMap    = 3
const TypeDefUnion  = 4
const TypeDefEnum   = 5
const TypeDefError  = 6
const TypeDefName   = 7

# buf is the payload of a Types frame
function decodeTypes!(ctx, buf, pos, len)
    while pos <= len
        startpos = pos
        b = buf[pos]
        pos += 1
        if b == TypeDefRecord
            nfields, pos = readuvarint(buf, pos, len)
            #TODO: we could probably skip allocating this fields
            # array + each field and just scan the full type def
            # and check if we've seen it in the TypeContext 1st
            # and go back and fully parse them all if not
            fields = Vector{Field}(undef, nfields)
            for i = 1:nfields
                name, pos = readCountedString(buf, pos, len)
                id, pos = readuvarint(buf, pos, len)
                T = ztype(ctx, id)
                fields[i] = Field(name, T)
            end
            add!(ctx, buf, startpos, pos) do id
                TypeRecord(id, fields)
            end
        elseif b == TypeDefArray || b == TypeDefSet || b == TypeDefError
            id, pos = readuvarint(buf, pos, len)
            inner = ztype(ctx, id)
            add!(ctx, buf, startpos, pos) do id
                b == TypeDefArray ? TypeArray(id, inner) : b == TypeDefSet ? TypeSet(id, inner) : TypeError(id, inner)
            end
        elseif b == TypeDefMap
            id, pos = readuvarint(buf, pos, len)
            keytype = ztype(ctx, id)
            id, pos = readuvarint(buf, pos, len)
            valtype = ztype(ctx, id)
            add!(ctx, buf, startpos, pos) do id
                TypeMap(id, keytype, valtype)
            end
        elseif b == TypeDefUnion
            ntyp, pos = readuvarint(buf, pos, len)
            @assert ntyp > 0
            types = Vector{ZType}(undef, ntyp)
            for i = 1:ntyp
                id, pos = readuvarint(buf, pos, len)
                types[i] = ztype(ctx, id)
            end
            add!(ctx, buf, startpos, pos) do id
                TypeUnion(id, types)
            end
        elseif b == TypeDefEnum
            nsym, pos = readuvarint(buf, pos, len)
            symbols = Vector{String}(undef, nsym)
            for i = 1:nsym
                name, pos = readCountedString(buf, pos, len)
                symbols[i] = name
            end
            add!(ctx, buf, startpos, pos) do id
                TypeEnum(id, symbols)
            end
        elseif b == TypeDefName
            name, pos = readCountedString(buf, pos, len)
            id, pos = readuvarint(buf, pos, len)
            inner = ztype(ctx, id)
            add!(ctx, buf, startpos, pos) do id
                TypeNamed(id, name, inner)
            end
        else
            error("unsupported type definition: $b")
        end
    end
end

function readCountedString(buf, pos, len)
    n, pos = readuvarint(buf, pos, len)
    str = unsafe_string(pointer(buf, pos), n)
    return str, pos + n
end
