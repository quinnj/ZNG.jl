module ZNG

using CodecLz4, EnumX, Structs

include("utils.jl")
include("types.jl")
include("values.jl")

const EOS = 0xff
primitive type FrameCode 8 end
uint8(x::FrameCode) = Base.bitcast(UInt8, x)
FrameCode(x::UInt8) = Base.bitcast(FrameCode, x)

@enumx FrameType Types=0b00000000 Values=0b00010000 Control=0b00100000 EndOfStream=0b00110000

Base.propertynames(::FrameCode) = (:version, :compressed, :type, :length)
function Base.getproperty(c::FrameCode, nm::Symbol)
    if nm == :version
        return uint8(c) & 0b10000000 > 0 ? 1 : 0
    elseif nm == :compressed
        return uint8(c) & 0b01000000 > 0
    elseif nm == :type
        return FrameType.T(uint8(c) & 0b00110000)
    elseif nm == :length
        return Int(uint8(c) & 0b00001111)
    else
        error("unknown property name: " + nm)
    end
end

struct Frame
    code::FrameCode
    length::Int
    payload::Vector{UInt8} # uncompressed
    pos::Int
end

function readframe(buf, pos, len)
    pos > len && error("Unexpected EOF")
    b = buf[pos]
    pos += 1
    code = FrameCode(b)
    code.version == 0 || error("unsupported version")
    vi, pos = readuvarint(buf, pos, len)
    framelen = Int((vi << 4) + code.length)
    payload, frlen, frpos = code.compressed ? decompress(buf, pos, len, framelen) : (buf, framelen, pos)
    return Frame(code, frlen, payload, frpos), pos + framelen
end

@enum CompressionFormat CompressionFormatLZ4=0x00

function decompress(buf, pos, len, framelen)
    pos > len && error("Unexpected EOF")
    f = buf[pos]
    CompressionFormat(f) == CompressionFormatLZ4 || error("unsupported compression format: " + f)
    pos += 1
    startpos = pos
    uncompressedSize, pos = readuvarint(buf, pos, len)
    GC.@preserve buf begin
        compressedPayload = unsafe_wrap(Array, pointer(buf, pos), framelen - (pos - startpos) - 1)
        return lz4_decompress(compressedPayload, uncompressedSize), uncompressedSize, 1
    end
end

function _read(buf, pos=1, len=length(buf))
    values = Value[]
    frames = Frame[]
    ctx = TypeContext()
    #TODO: implement control frame handling
    #TODO: allow concurrent frame reading
      # we'll want to push frame decompressing down to the decodeTypes or readvalue functions
    while pos <= len
        if buf[pos] == EOS
            # encountered end-of-stream, reset type context, then continue reading
            pos += 1
            continue
        end
        frame, pos = readframe(buf, pos, len)
        push!(frames, frame)
        if frame.code.type == FrameType.Values
            push!(values, readvalue(ctx, frame.payload, frame.pos, frame.length))
        elseif frame.code.type == FrameType.Types
            decodeTypes!(ctx, frame.payload, frame.pos, frame.length)
        elseif frame.code.type == FrameType.Control

        else
            error("unsupported frame type: " + frame.code.type)
        end
    end
    return values, frames, ctx
end

function read(buf, pos=1, len=length(buf))
    values, frames, ctx = _read(buf, pos, len)
    return length(values) == 1 ? values[1] : values
end

end # module ZNG

# TODO
 # writing
 # zed_jll for round-trip testing of all types
 # benchmark
 # concurrent frame reading/writing?
 # basic control frame decoding
