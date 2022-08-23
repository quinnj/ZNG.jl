function readvarint(buf, pos, len)
    T = Int64
    x = 0
    shift = 0
    while pos <= len
        @inbounds b = buf[pos]
        pos += 1
        x |= T(b & 0x7F) << shift
        shift += 7
        (b & 0x80) == 0 && return x, pos
    end
    return x, pos
end

fromzigzag(x::T) where {T <: Integer} =
    xor(x >> 1, -(x & T(1)))

_string(buf, pos, n) = unsafe_string(pointer(buf, pos), n)