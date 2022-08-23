struct Value
    type::ZType
    buf::Vector{UInt8}
    pos::Int
    n::Int
end

Base.show(io::IO, x::Value) = show(io, x[])

function Base.getindex(x::Value)
    # deserialize based on type
    if x.n == -1
        return nothing
    end
    T = x.type
    if T isa Types.Integer
        v, _ = readvarint(x.buf, x.pos, x.n)
        return fromzigzag(juliatype(T)(v))
    elseif T isa Types.Float
        ptr::Ptr{juliatype(T)} = pointer(x.buf, x.pos)
        return unsafe_load(ptr)
    elseif T isa Types.Number
        # decimal types
        error("unimplemented: $T")
    elseif T == Types.Bool
        return x.buf[x.pos] == 1
    elseif T == Types.Bytes
        return slice(x.buf, x.pos, x.n)
    elseif T == Types.String
        return _string(x.buf, x.pos, x.n)
    elseif T == Types.IP
        return _string(x.buf, x.pos, x.n)
    elseif T == Types.Net
        return _string(x.buf, x.pos, x.n)
    elseif T == Types.TypeZ
        return _string(x.buf, x.pos, x.n)
    elseif T == Types.Null
        return nothing
    elseif T isa RecordType
        n = length(T.columns)
        names = Vector{Symbol}(undef, n)
        values = Vector{Any}(undef, n)
        buf = x.buf
        pos = x.pos
        len = length(x.buf)
        for i = 1:n
            col = T.columns[i]
            names[i] = Symbol(col.name)
            n, pos = readtag(buf, pos, len)
            values[i] = Value(col.type, buf, pos, n)[]
            pos += n
        end
        return Record(names, values)
    else
        error("unsupported type: $T")
    end
end

function readtag(buf, pos, len)
    u64, pos = readvarint(buf, pos, len)
    return u64 == 0 ? -1 : u64 - 1, pos
end

function readvalues(ctx, buf)
    # buf is the payload of a Values frame
    pos = 1
    len = length(buf)
    values = Value[]
    while pos <= len
        id, pos = readvarint(buf, pos, len)
        n, pos = readtag(buf, pos, len)
        # @show id
        push!(values, Value(ztype(ctx, id), buf, pos, n))
        pos += n
    end
    return values
end