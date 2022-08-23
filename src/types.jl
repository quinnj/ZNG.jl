module Types

export typeid, ztype, juliatype, ZType

abstract type ZType end

abstract type Primitive <: ZType end

abstract type Number <: Primitive end
abstract type Integer <: Number end
abstract type Signed <: Integer end
abstract type Float <: Number end

abstract type Record <: ZType end
abstract type Array <: ZType end
abstract type Set <: ZType end
abstract type Map <: ZType end
abstract type Union <: ZType end
abstract type Enum <: ZType end
abstract type Error <: ZType end

# by default, types store their id
# primitive types overload directly
typeid(x) = x.id
ztype(id) = ZTYPE_PRIMITIVES[id]

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
    toType::Dict{String, ZType}
    toValue::Dict{ZType, String}
    typedefs::Dict{String, TypeNamed}
    # stringErr *TypeError
    # missing   *Value
    # quiet     *Value
end

TypeContext() = TypeContext(ReentrantLock(), Vector{ZType}(undef, typeid(Types.TypeComplex) - 1), Dict{String, ZType}(), Dict{ZType, String}(), Dict{String, TypeNamed}())
# MUST be called while holding lock
nextid(ctx) = length(ctx.byID) + 1

# MUST be called while holding lock
function add!(c, type::ZType)
    tv = string(type)
    c.toValue[type] = tv
    c.toType[tv] = type
    push!(c.byID, type)
    return
end

function Types.ztype(ctx::TypeContext, id::Int)
    if id < typeid(Types.TypeComplex)
        # primitive type
        return Types.ztype(id)
    end
    Base.@lock ctx.lock begin
        return ctx.byID[id]
    end
end

struct Column
    name::String
    type::ZType
end

struct RecordType <: ZType
    id::Int
    columns::Vector{Column}
    lu::Dict{String, Int} # column name => column index
end

RecordType(id, cols) = RecordType(id, cols, Dict(c.name => i for (i, c) in enumerate(cols)))

# lazy NamedTuple; instance of a RecordType object
struct Record
    names::Vector{Symbol}
    values::Vector{Any}
end

Base.propertynames(x::Record) = x.names
function Base.getproperty(x::Record, nm::Symbol)
    i = 1
    for n in getfield(x, :names)
        if n === nm
            return @inbounds getfield(x, :values)[i]
        end
        i += 1
    end
    error("Record has no property $nm")
end

function Base.show(io::IO, x::Record)
    print(io, "Record(")
    for (i, n) in enumerate(getfield(x, :names))
        if i > 1
            print(io, ", ")
        end
        print(io, n, " = ")
        show(io, getfield(x, :values)[i])
    end
    print(io, ")")
end

const TypeDefRecord = 0
const TypeDefArray  = 1
const TypeDefSet    = 2
const TypeDefMap    = 3
const TypeDefUnion  = 4
const TypeDefEnum   = 5
const TypeDefError  = 6
const TypeDefName   = 7

# buf is the payload of a Types frame
function decodeTypes!(ctx, buf)
    pos = 1
    len = length(buf)
    while pos <= len
        b = buf[pos]
        pos += 1
        if b == TypeDefRecord
            ncols, pos = readvarint(buf, pos, len)
            cols = Vector{Column}(undef, ncols)
            for i = 1:ncols
                name, pos = readCountedString(buf, pos, len)
                id, pos = readvarint(buf, pos, len)
                T = ztype(ctx, id)
                cols[i] = Column(name, T)
            end
            # duplicate column check
            # lookup type by string representation
            # otherwise, create new type and insert into type context
            Base.@lock ctx.lock begin
                id = nextid(ctx)
                rec = RecordType(id, cols)
                add!(ctx, rec)
            end
        elseif b == TypeDefArray
            
        elseif b == TypeDefSet
            
        elseif b == TypeDefMap
            
        elseif b == TypeDefUnion
            
        elseif b == TypeDefEnum
            
        elseif b == TypeDefError
            
        elseif b == TypeDefName

        else
            error("unsupported type definition: " + b)
        end
    end
end

function readCountedString(buf, pos, len)
    n, pos = readvarint(buf, pos, len)
    str = unsafe_string(pointer(buf, pos), n)
    return str, pos + n
end
