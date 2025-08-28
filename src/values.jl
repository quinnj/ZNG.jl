struct Value
    type::ZType
    buf::Vector{UInt8}
    pos::Int
    n::Int
end

Structs.@selectors Value

gettype(x::Value) = getfield(x, :type)
getbuf(x::Value) = getfield(x, :buf)
getpos(x::Value) = getfield(x, :pos)
getn(x::Value) = getfield(x, :n)
@inline getfields(x::Value) = (gettype(x), getbuf(x), getpos(x), getn(x))

function uniontype(x::Value)
    type = gettype(x)
    @assert type isa TypeUnion
    _, buf, pos, n = getfields(x)
    n, pos = readtag(buf, pos, pos + n - 1)
    id = decode_counted_varint(buf, pos, n)
    return type.types[id + 1]
end

function Types.juliatype(f, x::Value)
    type = gettype(x)
    if type isa TypeRecord
        #TODO: can we do anything more efficient here than dynamically constructing a NamedTuple type?
        Types.juliatype(T -> f(NamedTuple{Tuple(Symbol(f.name) for f in type.fields), Tuple{(juliatype(f.type) for f in type.fields)...}}), type)
    elseif type isa TypeArray
        Types.juliatype(T -> f(Vector{T}), type.type)
    elseif type isa TypeSet
        Types.juliatype(T -> f(Set{T}), type.type)
    elseif type isa TypeUnion
        _, buf, pos, n = getfields(x)
        n, pos = readtag(buf, pos, pos + n - 1)
        id = decode_counted_varint(buf, pos, n)
        Types.juliatype(f, type.types[id + 1])
    else
        Types.juliatype(f, type)
    end
end

Base.show(io::IO, x::Value) = show(io, x[])

struct ZNGStyle <: Structs.StructStyle end

Structs.structlike(x::Value) = gettype(x) isa TypeRecord || gettype(x) isa TypeUnion && Structs.structlike(uniontype(x))
Structs.arraylike(x::Value) = gettype(x) isa TypeArray || gettype(x) isa TypeSet || gettype(x) isa TypeUnion && Structs.arraylike(uniontype(x))
Structs.nulllike(x::Value) = getn(x) == -1 || gettype(x) == Types.Null || gettype(x) isa TypeUnion && Structs.nulllike(uniontype(x))

@inline function Structs.choosetype(f::F, style::Structs.StructStyle, ::Type{T}, x::Value, tags) where {F, T}
    return Types.juliatype(type -> f(style, type, x, tags), x)
end

Base.getindex(x::Value) = Structs.make(ZNGStyle(), Any, x)

@inline function Structs.lift(f::F, style::Structs.StructStyle, ::Type{T}, x::Value, tags) where {F, T}
    # deserialize based on type
    type, buf, pos, n = getfields(x)
    if type == Types.Null || n == -1
        return Structs.lift(f, style, T, nothing, tags)
    end
    if type isa Types.Signed
        v = decode_counted_varint(buf, pos, n)
        return Structs.lift(f, style, T, v, tags)
    elseif type isa Types.Integer
        v = decode_counted_uvarint(buf, pos, n)
        return Structs.lift(f, style, T, v, tags)
    elseif type isa Types.Float
        ptr::Ptr{juliatype(type)} = pointer(buf, pos)
        return Structs.lift(f, style, T, unsafe_load(ptr), tags)
    elseif type isa Types.Number
        # decimal types
        error("unimplemented: $type")
    elseif type == Types.Bool
        return Structs.lift(f, style, T, buf[pos] == 1, tags)
    elseif type == Types.Bytes
        return Structs.lift(f, style, T, buf[pos:pos+n-1], tags)
    elseif type == Types.String
        str = _string(buf, pos, n)
        return Structs.lift(f, style, T, str, tags)
    elseif type == Types.IP
        return Structs.lift(f, style, T, _string(buf, pos, n), tags)
    elseif type == Types.Net
        return Structs.lift(f, style, T, _string(buf, pos, n), tags)
    elseif type == Types.TypeZ
        return Structs.lift(f, style, T, _string(buf, pos, n), tags)
    else
        error("unsupported type: $type")
    end
end

@inline function Structs.applyeach(style::Structs.StructStyle, f::F, x::Value) where {F}
    type, buf, pos, n = getfields(x)
    len = pos + n - 1
    while type isa TypeNamed || type isa TypeUnion
        if type isa TypeNamed
            type = type.type
        elseif type isa TypeUnion
            n, pos = readtag(buf, pos, len)
            id = decode_counted_varint(buf, pos, n)
            type = type.types[id+1]
            pos += n
            n, pos = readtag(buf, pos, len)
        end
    end
    if type isa TypeRecord
        fields = type.fields
        for i = 1:length(fields)
            field = fields[i]
            n, pos = readtag(buf, pos, len)
            v = Value(field.type, buf, pos, n)
            ret = f(field.name, v)
            ret isa Structs.EarlyReturn && return ret
            pos += n
        end
    elseif type isa TypeArray || type isa TypeSet
        i = 1
        while pos <= len
            n, pos = readtag(buf, pos, len)
            v = Value(type.type, buf, pos, n)
            ret = f(i, v)
            ret isa Structs.EarlyReturn && return ret
            pos += n
            i += 1
        end
    else
        error("unsupported type: $type")
    end
end

function readtag(buf, pos, len)
    u64, pos = readuvarint(buf, pos, len)
    return u64 == 0 ? -1 : u64 - 1, pos
end

# buf, pos, len = frame.payload, frame.pos, frame.length
function readvalue(ctx, buf, pos, len)
    # buf is the payload of a Values frame
    # each top-level value is preceeded by a varint type id
    # that MUST correspond to a type definition in a Types frame
    id, pos = readuvarint(buf, pos, len)
    # every value is tag-encoded, which gives us the length of the value
    n, pos = readtag(buf, pos, len)
    return Value(ztype(ctx, id), buf, pos, n)
end