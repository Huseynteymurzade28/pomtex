require "../ui"

# The slice of liblzma's API that decoding .xz needs.
@[Link("lzma")]
lib LibLZMA
  # Mirrors `lzma_stream`; LZMA_STREAM_INIT is all zeroes.
  struct Stream
    next_in : UInt8*
    avail_in : LibC::SizeT
    total_in : UInt64
    next_out : UInt8*
    avail_out : LibC::SizeT
    total_out : UInt64
    allocator : Void*
    internal : Void*
    reserved_ptr1 : Void*
    reserved_ptr2 : Void*
    reserved_ptr3 : Void*
    reserved_ptr4 : Void*
    seek_pos : UInt64
    reserved_int2 : UInt64
    reserved_int3 : LibC::SizeT
    reserved_int4 : LibC::SizeT
    reserved_enum1 : Int32
    reserved_enum2 : Int32
  end

  enum Ret : Int32
    OK                =  0
    STREAM_END        =  1
    NO_CHECK          =  2
    UNSUPPORTED_CHECK =  3
    GET_CHECK         =  4
    MEM_ERROR         =  5
    MEMLIMIT_ERROR    =  6
    FORMAT_ERROR      =  7
    OPTIONS_ERROR     =  8
    DATA_ERROR        =  9
    BUF_ERROR         = 10
    PROG_ERROR        = 11
  end

  enum Action : Int32
    RUN    = 0
    FINISH = 3
  end

  CONCATENATED = 0x08_u32

  fun stream_decoder = lzma_stream_decoder(strm : Stream*, memlimit : UInt64, flags : UInt32) : Ret
  fun code = lzma_code(strm : Stream*, action : Action) : Ret
  fun end_ = lzma_end(strm : Stream*) : Void
  fun version_string = lzma_version_string : UInt8*
end

module Pomtex::Seed::XZ
  # A read-only IO that decompresses an .xz stream (concatenated streams
  # included) from the wrapped IO. Reaching the end verifies the checksums.
  class Reader < IO
    BUFFER_SIZE = 64 * 1024

    @stream = LibLZMA::Stream.new
    @input = Bytes.new(BUFFER_SIZE)
    @eof = false
    @finished = false
    @closed = false

    def initialize(@io : IO)
      check LibLZMA.stream_decoder(pointerof(@stream), UInt64::MAX, LibLZMA::CONCATENATED)
    end

    def self.open(io : IO, & : self ->)
      reader = new(io)
      begin
        yield reader
      ensure
        reader.close
      end
    end

    def read(slice : Bytes) : Int32
      check_open
      return 0 if slice.empty? || @finished
      @stream.next_out = slice.to_unsafe
      @stream.avail_out = slice.size
      loop do
        if @stream.avail_in == 0 && !@eof
          count = @io.read(@input)
          if count == 0
            @eof = true
          else
            @stream.next_in = @input.to_unsafe
            @stream.avail_in = count
          end
        end
        ret = LibLZMA.code(pointerof(@stream), @eof ? LibLZMA::Action::FINISH : LibLZMA::Action::RUN)
        produced = slice.size - @stream.avail_out.to_i32
        case ret
        when .stream_end?
          @finished = true
          return produced
        when .ok?
          return produced if produced > 0
        else
          check ret
        end
      end
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("Can't write to XZ::Reader")
    end

    def close : Nil
      return if @closed
      @closed = true
      LibLZMA.end_(pointerof(@stream))
    end

    def closed? : Bool
      @closed
    end

    private def check(ret : LibLZMA::Ret) : Nil
      message = case ret
                when .ok?, .stream_end? then return
                when .mem_error?        then "out of memory"
                when .format_error?     then "not in .xz format"
                when .options_error?    then "unsupported compression options"
                when .data_error?       then "data is corrupt"
                when .buf_error?        then "unexpected end of input"
                else                         "liblzma error #{ret.value}"
                end
      raise Pomtex::Error.new("xz: #{message}")
    end
  end
end
