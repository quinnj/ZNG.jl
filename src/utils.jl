fromzigzag(x::T) where {T <: Integer} =
    xor(x >> 1, -(x & T(1)))

_string(buf, pos, n) = unsafe_string(pointer(buf, pos), n)

function decode_counted_uvarint(b::AbstractVector{UInt8}, pos, n)
    n = pos + n - 1
    u64 = UInt64(0)
    while n >= pos
        n -= 1
        u64 <<= 8
        u64 |= UInt64(b[n + 1])
    end
    return u64
end

# func DecodeCountedUvarint(b []byte) uint64 {
# 	n := len(b)
# 	println("n", n)
# 	u64 := uint64(0)
# 	for n > 0 {
# 		n--
# 		u64 <<= 8
# 		println("b[n]", b[n])
# 		u64 |= uint64(b[n])
# 	}
# 	return u64
# }

function encode_counted_uvarint(dst::AbstractVector{UInt8}, u64::UInt64)
    n = 0
    while u64 != 0
        dst[n+1] = u64 % UInt8
        u64 >>= 8
        n += 1
    end
    return n
end

function append_counted_uvarint(dst::AbstractVector{UInt8}, u64::UInt64)
    while u64 != 0
        push!(dst, u64 % UInt8)
        u64 >>= 8
    end
    if isempty(dst)
        # Input was a zero. Since zero was "appended" but encoded
        # as nothing, return an empty vector so we don't turn an
        # append zero into an append null.
        dst = UInt8[]
    end
    return dst
end

function decode_counted_varint(b::AbstractVector{UInt8}, pos, n)
    u64 = decode_counted_uvarint(b, pos, n)
    if u64 & 1 != 0
        u64 >>= 1
        if u64 == 0
            return typemin(Int64)
        end
        return -Base.bitcast(Int64, u64)
    end
    return Base.bitcast(Int64, u64 >> 1)
end

function encode_counted_varint(dst::AbstractVector{UInt8}, i::Int64)
    if i >= 0
        u64 = UInt64(i) << 1
    else
        u64 = UInt64(-i) << 1 | 1
    end
    return encode_counted_uvarint(dst, u64)
end

function append_counted_varint(dst::AbstractVector{UInt8}, i::Int64)
    if i >= 0
        u64 = UInt64(i) << 1
    else
        u64 = UInt64(-i) << 1 | 1
    end
    return append_counted_uvarint(dst, u64)
end

function readuvarint(buf, pos, len)
    x = UInt64(0)
    shift = 0
    while pos <= len
        @inbounds b = buf[pos]
        pos += 1
        x |= UInt64(b & 0x7F) << shift
        shift += 7
        (b & 0x80) == 0 && return x, pos
    end
    return x, pos
end

function readvarint(buf, pos, len)
    ux, pos = readuvarint(buf, pos, len)
    x = Base.bitcast(Int64, ux >> 1)
    ux & 1 != 0 && return ~x, pos
    return x, pos
end
