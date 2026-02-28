# frozen_string_literal: true

require "digest"
require "stringio"
require "tempfile"

class FlacSpecBitWriter
  def initialize
    @bytes = []
    @current = 0
    @bits_used = 0
  end

  def write_bits(value, count)
    count.times do |shift_index|
      shift = (count - 1) - shift_index
      bit = (value >> shift) & 0x1
      @current = (@current << 1) | bit
      @bits_used += 1
      flush_current_byte_if_needed
    end
  end

  def write_signed_bits(value, count)
    mask = (1 << count) - 1
    write_bits(value & mask, count)
  end

  def write_unary_zeros_then_one(zero_count)
    zero_count.times { write_bits(0, 1) }
    write_bits(1, 1)
  end

  def write_rice_signed(value, parameter)
    unsigned = value >= 0 ? (value << 1) : ((-value << 1) - 1)
    quotient = unsigned >> parameter
    remainder = parameter.zero? ? 0 : (unsigned & ((1 << parameter) - 1))

    write_unary_zeros_then_one(quotient)
    write_bits(remainder, parameter) if parameter.positive?
  end

  def align_byte
    return if @bits_used.zero?

    @current <<= (8 - @bits_used)
    @bytes << @current
    @current = 0
    @bits_used = 0
  end

  def to_s
    align_byte
    @bytes.pack("C*")
  end

  private

  def flush_current_byte_if_needed
    return unless @bits_used == 8

    @bytes << @current
    @current = 0
    @bits_used = 0
  end
end

RSpec.describe Wavify::Codecs::Flac do
  def spec_flac_crc8(data)
    crc = 0
    data.each_byte do |byte|
      crc ^= byte
      8.times do
        crc = crc.nobits?(0x80) ? (crc << 1) : ((crc << 1) ^ 0x07)
        crc &= 0xFF
      end
    end
    crc
  end

  def spec_flac_crc16(data)
    crc = 0
    data.each_byte do |byte|
      crc ^= (byte << 8)
      8.times do
        crc = crc.nobits?(0x8000) ? (crc << 1) : ((crc << 1) ^ 0x8005)
        crc &= 0xFFFF
      end
    end
    crc
  end

  def spec_pcm_md5_hex(samples, format)
    packed = case format.bit_depth
             when 8
               samples.pack("c*")
             when 16
               samples.pack("s<*")
             when 24
               bytes = samples.flat_map do |sample|
                 value = sample
                 value += 0x1000000 if value.negative?
                 [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
               end
               bytes.pack("C*")
             when 32
               samples.pack("l<*")
             else
               raise "unsupported spec md5 bit depth"
             end
    Digest::MD5.hexdigest(packed)
  end

  def build_streaminfo_bytes(sample_rate:, channels:, bit_depth:, total_samples:)
    min_block_size = 4096
    max_block_size = 4096
    min_frame_size = [0, 0, 0].pack("C3")
    max_frame_size = [0, 0, 0].pack("C3")
    packed = ((sample_rate & 0xFFFFF) << 44) |
             (((channels - 1) & 0x7) << 41) |
             (((bit_depth - 1) & 0x1F) << 36) |
             (total_samples & 0xFFFFFFFFF)

    [min_block_size, max_block_size].pack("n2") +
      min_frame_size +
      max_frame_size +
      [packed].pack("Q>") +
      ("\x00" * 16)
  end

  def build_flac_bytes_with_streaminfo(sample_rate:, channels:, bit_depth:, total_samples:, frame_bytes: nil)
    streaminfo = build_streaminfo_bytes(
      sample_rate: sample_rate,
      channels: channels,
      bit_depth: bit_depth,
      total_samples: total_samples
    )
    header = [0x80, 0x00, 0x00, streaminfo.bytesize].pack("C4")
    bytes = +"fLaC"
    bytes << header
    bytes << streaminfo
    bytes << frame_bytes if frame_bytes
    bytes
  end

  def build_flac_frame_16bit(
    samples_per_channel,
    subframe_type: :verbatim,
    channel_assignment: nil,
    channel_sample_sizes: nil,
    wasted_bits: 0
  )
    channels = samples_per_channel.length
    block_size = samples_per_channel.first.length
    raise "empty frame" if channels.zero? || block_size.zero?
    raise "inconsistent channel lengths" unless samples_per_channel.all? { |channel| channel.length == block_size }
    raise "unsupported channel count" unless channels.between?(1, 8)

    writer = FlacSpecBitWriter.new
    writer.write_bits(0x3FFE, 14) # sync code
    writer.write_bits(0, 1) # reserved
    writer.write_bits(0, 1) # fixed-blocksize stream
    writer.write_bits(6, 4) # block size in 8-bit field (n-1)
    writer.write_bits(0, 4) # sample rate from STREAMINFO
    writer.write_bits(channel_assignment || (channels - 1), 4)
    writer.write_bits(0, 3) # sample size from STREAMINFO
    writer.write_bits(0, 1) # reserved
    writer.write_bits(0, 8) # frame number = 0 (UTF-8 coded)
    writer.write_bits(block_size - 1, 8)
    writer.write_bits(0, 8) # CRC-8 (parser ignores)

    type_code = case subframe_type
                when :constant then 0
                when :verbatim then 1
                when Integer then subframe_type
                else
                  raise "unknown subframe type: #{subframe_type.inspect}"
                end

    wasted_bits_per_channel =
      if wasted_bits.is_a?(Array)
        raise "wasted_bits size mismatch" unless wasted_bits.length == channels

        wasted_bits
      else
        Array.new(channels, wasted_bits)
      end

    samples_per_channel.each_with_index do |channel_samples, channel_index|
      sample_bits = channel_sample_sizes&.fetch(channel_index, 16) || 16
      channel_wasted_bits = wasted_bits_per_channel.fetch(channel_index).to_i
      raise "invalid wasted bits" if channel_wasted_bits.negative? || channel_wasted_bits >= sample_bits

      encoded_sample_bits = sample_bits - channel_wasted_bits

      writer.write_bits(0, 1) # zero padding bit
      writer.write_bits(type_code, 6)
      writer.write_bits(channel_wasted_bits.zero? ? 0 : 1, 1)
      writer.write_unary_zeros_then_one(channel_wasted_bits - 1) if channel_wasted_bits.positive?

      case subframe_type
      when :constant
        writer.write_signed_bits(channel_samples.first >> channel_wasted_bits, encoded_sample_bits)
      else
        channel_samples.each do |sample|
          writer.write_signed_bits(sample >> channel_wasted_bits, encoded_sample_bits)
        end
      end
    end

    writer.align_byte
    writer.write_bits(0, 16) # CRC-16 (parser ignores)
    writer.to_s
  end

  def fixed_predictor_residuals(samples, predictor_order)
    raise "predictor order out of range" unless predictor_order.between?(0, 4)
    raise "block too short" if samples.length < predictor_order

    warmup = samples.first(predictor_order)
    residuals = samples.drop(predictor_order).each_with_object([]) do |sample, result|
      predicted = case predictor_order
                  when 0
                    0
                  when 1
                    warmup[-1]
                  when 2
                    (2 * warmup[-1]) - warmup[-2]
                  when 3
                    (3 * warmup[-1]) - (3 * warmup[-2]) + warmup[-3]
                  when 4
                    (4 * warmup[-1]) - (6 * warmup[-2]) + (4 * warmup[-3]) - warmup[-4]
                  end
      residual = sample - predicted
      result << residual
      warmup << sample
      warmup.shift if predictor_order.positive? && warmup.length > predictor_order
    end

    [samples.first(predictor_order), residuals]
  end

  def build_flac_fixed_frame_16bit(samples_per_channel, predictor_order:, rice_parameter: 0)
    channels = samples_per_channel.length
    block_size = samples_per_channel.first.length
    raise "empty frame" if channels.zero? || block_size.zero?
    raise "inconsistent channel lengths" unless samples_per_channel.all? { |channel| channel.length == block_size }

    writer = FlacSpecBitWriter.new
    writer.write_bits(0x3FFE, 14)
    writer.write_bits(0, 1)
    writer.write_bits(0, 1)
    writer.write_bits(6, 4)
    writer.write_bits(0, 4)
    writer.write_bits(channels - 1, 4)
    writer.write_bits(0, 3)
    writer.write_bits(0, 1)
    writer.write_bits(0, 8)
    writer.write_bits(block_size - 1, 8)
    writer.write_bits(0, 8)

    samples_per_channel.each do |channel_samples|
      warmup, residuals = fixed_predictor_residuals(channel_samples, predictor_order)
      writer.write_bits(0, 1)
      writer.write_bits(8 + predictor_order, 6)
      writer.write_bits(0, 1)
      warmup.each { |sample| writer.write_signed_bits(sample, 16) }

      writer.write_bits(0, 2) # Rice
      writer.write_bits(0, 4) # partition order = 0
      writer.write_bits(rice_parameter, 4)
      residuals.each { |sample| writer.write_rice_signed(sample, rice_parameter) }
    end

    writer.align_byte
    writer.write_bits(0, 16)
    writer.to_s
  end

  def lpc_residuals(samples, coefficients, qlp_shift)
    order = coefficients.length
    history = samples.first(order).dup

    samples.drop(order).each_with_object([]) do |sample, residuals|
      sum = 0
      coefficients.each_with_index do |coefficient, index|
        sum += coefficient * history[-1 - index]
      end
      predicted = qlp_shift.negative? ? (sum << -qlp_shift) : (sum >> qlp_shift)
      residuals << (sample - predicted)

      history << sample
      history.shift if history.length > order
    end
  end

  def build_flac_lpc_frame_16bit(samples_per_channel, coefficients:, qlp_shift:, coefficient_precision:, rice_parameter: 0)
    channels = samples_per_channel.length
    block_size = samples_per_channel.first.length
    order = coefficients.length
    raise "empty frame" if channels.zero? || block_size.zero?
    raise "invalid LPC order" if order.zero?
    raise "block too short" if block_size < order
    raise "inconsistent channel lengths" unless samples_per_channel.all? { |channel| channel.length == block_size }

    writer = FlacSpecBitWriter.new
    writer.write_bits(0x3FFE, 14)
    writer.write_bits(0, 1)
    writer.write_bits(0, 1)
    writer.write_bits(6, 4)
    writer.write_bits(0, 4)
    writer.write_bits(channels - 1, 4)
    writer.write_bits(0, 3)
    writer.write_bits(0, 1)
    writer.write_bits(0, 8)
    writer.write_bits(block_size - 1, 8)
    writer.write_bits(0, 8)

    samples_per_channel.each do |channel_samples|
      residuals = lpc_residuals(channel_samples, coefficients, qlp_shift)

      writer.write_bits(0, 1)
      writer.write_bits(32 + order - 1, 6)
      writer.write_bits(0, 1)
      channel_samples.first(order).each { |sample| writer.write_signed_bits(sample, 16) }
      writer.write_bits(coefficient_precision - 1, 4)
      writer.write_signed_bits(qlp_shift, 5)
      coefficients.each { |coefficient| writer.write_signed_bits(coefficient, coefficient_precision) }

      writer.write_bits(0, 2) # Rice coding method
      writer.write_bits(0, 4) # partition order
      writer.write_bits(rice_parameter, 4)
      residuals.each { |sample| writer.write_rice_signed(sample, rice_parameter) }
    end

    writer.align_byte
    writer.write_bits(0, 16)
    writer.to_s
  end

  describe ".metadata" do
    it "parses STREAMINFO metadata" do
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 2,
        bit_depth: 16,
        total_samples: 44_100
      )
      io = StringIO.new(bytes)

      metadata = described_class.metadata(io)

      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      )
      expect(metadata[:sample_frame_count]).to eq(44_100)
      expect(metadata[:duration].total_seconds).to eq(1.0)
      expect(metadata[:min_block_size]).to eq(4096)
      expect(metadata[:max_block_size]).to eq(4096)
      expect(metadata[:md5]).to eq("0" * 32)
    end

    it "raises on missing streaminfo block" do
      io = StringIO.new(+"fLaC" << [0x84, 0x00, 0x00, 0x00].pack("C4"))

      expect do
        described_class.metadata(io)
      end.to raise_error(Wavify::InvalidFormatError)
    end
  end

  describe ".read" do
    it "decodes a verbatim frame for 16-bit pcm" do
      frame = build_flac_frame_16bit([[0, 1000, -1000, 32_767]])
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: 4,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer).to be_a(Wavify::Core::SampleBuffer)
      expect(buffer.format).to eq(
        Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      )
      expect(buffer.samples).to eq([0, 1000, -1000, 32_767])
    end

    it "decodes constant subframes" do
      frame = build_flac_frame_16bit([[42, 42, 42, 42], [-42, -42, -42, -42]], subframe_type: :constant)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 48_000,
        channels: 2,
        bit_depth: 16,
        total_samples: 4,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq([42, -42, 42, -42, 42, -42, 42, -42])
    end

    it "decodes verbatim subframes with wasted bits" do
      source = [12, -8, 20, 0]
      frame = build_flac_frame_16bit([source], wasted_bits: 2)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: source.length,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq(source)
    end

    it "decodes constant subframes with wasted bits" do
      frame = build_flac_frame_16bit([[64, 64, 64, 64]], subframe_type: :constant, wasted_bits: 3)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: 4,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq([64, 64, 64, 64])
    end

    it "decodes left-side stereo frames" do
      left = [100, 110, 120, 130]
      right = [4, 6, 8, 10]
      side = left.zip(right).map { |l, r| l - r }
      frame = build_flac_frame_16bit(
        [left, side],
        channel_assignment: 8,
        channel_sample_sizes: [16, 17]
      )
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 2,
        bit_depth: 16,
        total_samples: left.length,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq(left.zip(right).flatten)
    end

    it "decodes mid-side stereo frames with odd side values" do
      left = [101, 115, 130, 145]
      right = [98, 110, 123, 139]
      side = left.zip(right).map { |l, r| l - r }
      mid = left.zip(right).map { |l, r| (l + r) >> 1 }
      frame = build_flac_frame_16bit(
        [mid, side],
        channel_assignment: 10,
        channel_sample_sizes: [16, 17]
      )
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 48_000,
        channels: 2,
        bit_depth: 16,
        total_samples: left.length,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq(left.zip(right).flatten)
    end

    it "decodes fixed subframes with rice residual coding" do
      frame = build_flac_fixed_frame_16bit([[0, 3, -2, 5, -4, 6]], predictor_order: 0, rice_parameter: 2)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: 6,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq([0, 3, -2, 5, -4, 6])
    end

    it "reconstructs fixed predictor order 2 samples" do
      source = [1_000, 1_010, 1_020, 1_030, 1_040, 1_050]
      frame = build_flac_fixed_frame_16bit([source], predictor_order: 2, rice_parameter: 0)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 48_000,
        channels: 1,
        bit_depth: 16,
        total_samples: source.length,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq(source)
    end

    it "decodes lpc subframes (order 1)" do
      source = [1000, 1004, 1010, 1008, 1015, 1015]
      frame = build_flac_lpc_frame_16bit(
        [source],
        coefficients: [1],
        qlp_shift: 0,
        coefficient_precision: 4,
        rice_parameter: 2
      )
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: source.length,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq(source)
    end

    it "decodes lpc subframes (order 2) with zero residuals" do
      source = [100, 105, 110, 115, 120, 125]
      frame = build_flac_lpc_frame_16bit(
        [source],
        coefficients: [2, -1],
        qlp_shift: 0,
        coefficient_precision: 5,
        rice_parameter: 0
      )
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 48_000,
        channels: 1,
        bit_depth: 16,
        total_samples: source.length,
        frame_bytes: frame
      )

      buffer = described_class.read(StringIO.new(bytes))

      expect(buffer.samples).to eq(source)
    end

    it "raises for unsupported subframe types" do
      frame = build_flac_frame_16bit([[1, 2, 3, 4]], subframe_type: 13)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: 4,
        frame_bytes: frame
      )

      expect do
        described_class.read(StringIO.new(bytes))
      end.to raise_error(Wavify::UnsupportedFormatError, /subframe type/)
    end
  end

  describe ".write" do
    it "encodes PCM buffers as verbatim frames and round-trips via read" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      frames = 4_500
      samples = Array.new(frames) do |index|
        left = ((index * 17) % 20_000) - 10_000
        right = ((index * 31) % 16_000) - 8_000
        [left, right]
      end.flatten
      buffer = Wavify::Core::SampleBuffer.new(samples, format)
      io = StringIO.new(+"")

      described_class.write(io, buffer, format: format)

      decoded = described_class.read(io)
      metadata = described_class.metadata(io)

      expect(decoded.samples).to eq(samples)
      expect(decoded.format).to eq(format)
      expect(metadata[:sample_frame_count]).to eq(frames)
      expect(metadata[:min_block_size]).to eq(404)
      expect(metadata[:max_block_size]).to eq(4096)
      expect(metadata[:md5]).to eq(spec_pcm_md5_hex(samples, format))
    end

    it "writes valid frame CRC8/CRC16 values" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      samples = [0, 1000, -1000, 1200, -1200, 333, -333, 0]
      buffer = Wavify::Core::SampleBuffer.new(samples, format)
      io = StringIO.new(+"")

      described_class.write(io, buffer, format: format)

      bytes = io.string
      frame = bytes.byteslice(4 + 4 + 34, bytes.bytesize - (4 + 4 + 34))

      header_without_crc8 = frame.byteslice(0, 6)
      header_crc8 = frame.getbyte(6)
      crc16_input = frame.byteslice(0, frame.bytesize - 2)
      frame_crc16 = frame.byteslice(-2, 2).unpack1("n")

      expect(header_crc8).to eq(spec_flac_crc8(header_without_crc8))
      expect(frame_crc16).to eq(spec_flac_crc16(crc16_input))
    end

    it "uses fixed subframe encoding when it is smaller than verbatim" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      samples = [1000, 1010, 1020, 1030, 1040, 1050, 1060, 1070]
      buffer = Wavify::Core::SampleBuffer.new(samples, format)
      io = StringIO.new(+"")

      described_class.write(io, buffer, format: format)

      frame = io.string.byteslice(4 + 4 + 34, io.string.bytesize - (4 + 4 + 34))
      first_subframe_header_byte = frame.getbyte(7)
      subframe_type = (first_subframe_header_byte >> 1) & 0x3F

      expect(subframe_type).to eq(10) # fixed predictor order 2
      expect(described_class.read(io).samples).to eq(samples)
    end
  end

  describe ".stream_write" do
    it "writes verbatim FLAC frames from streamed chunks and finalizes STREAMINFO" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 16, sample_format: :pcm)
      samples1 = Array.new(5_000) { |index| ((index * 19) % 22_000) - 11_000 }
      samples2 = Array.new(300) { |index| ((index * 23) % 18_000) - 9_000 }
      chunk1 = Wavify::Core::SampleBuffer.new(samples1, format)
      chunk2 = Wavify::Core::SampleBuffer.new(samples2, format)
      io = StringIO.new(+"")

      described_class.stream_write(io, format: format) do |writer|
        writer.call(chunk1)
        writer.call(chunk2)
      end

      decoded = described_class.read(io)
      metadata = described_class.metadata(io)

      expect(decoded.samples).to eq(samples1 + samples2)
      expect(decoded.format).to eq(format)
      expect(metadata[:sample_frame_count]).to eq(5_300)
      expect(metadata[:min_block_size]).to eq(300)
      expect(metadata[:max_block_size]).to eq(4096)
      expect(metadata[:md5]).to eq(spec_pcm_md5_hex(samples1 + samples2, format))
    end

    it "supports fixed block size strategy across chunk boundaries" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      samples1 = [1, 2, 3]
      samples2 = [4, 5, 6, 7, 8]
      io = StringIO.new(+"")

      described_class.stream_write(io, format: format, block_size: 4, block_size_strategy: :fixed) do |writer|
        writer.call(Wavify::Core::SampleBuffer.new(samples1, format))
        writer.call(Wavify::Core::SampleBuffer.new(samples2, format))
      end

      metadata = described_class.metadata(io)

      expect(metadata[:sample_frame_count]).to eq(8)
      expect(metadata[:min_block_size]).to eq(4)
      expect(metadata[:max_block_size]).to eq(4)
      expect(described_class.read(io).samples).to eq(samples1 + samples2)
    end

    it "supports source_chunk block size strategy for variable frame sizes" do
      format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      samples1 = [10, 20, 30]
      samples2 = [40, 50, 60, 70, 80]
      io = StringIO.new(+"")

      described_class.stream_write(io, format: format, block_size: 4, block_size_strategy: :source_chunk) do |writer|
        writer.call(Wavify::Core::SampleBuffer.new(samples1, format))
        writer.call(Wavify::Core::SampleBuffer.new(samples2, format))
      end

      metadata = described_class.metadata(io)

      expect(metadata[:sample_frame_count]).to eq(8)
      expect(metadata[:min_block_size]).to eq(3)
      expect(metadata[:max_block_size]).to eq(5)
      expect(described_class.read(io).samples).to eq(samples1 + samples2)
    end
  end

  describe ".stream_read" do
    it "yields decoded chunks as sample buffers" do
      source = [100, 110, 120, 130, 140, 150]
      frame = build_flac_fixed_frame_16bit([source], predictor_order: 2, rice_parameter: 0)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: source.length,
        frame_bytes: frame
      )

      chunks = []
      described_class.stream_read(StringIO.new(bytes), chunk_size: 2) { |chunk| chunks << chunk }

      expect(chunks.map(&:sample_frame_count)).to eq([2, 2, 2])
      expect(chunks.flat_map(&:samples)).to eq(source)
      expect(chunks.map(&:format).uniq).to eq(
        [Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)]
      )
    end

    it "streams across multiple frames without using .read" do
      frame1 = build_flac_fixed_frame_16bit([[10, 20, 30, 40]], predictor_order: 0, rice_parameter: 2)
      frame2 = build_flac_fixed_frame_16bit([[50, 60, 70]], predictor_order: 0, rice_parameter: 2)
      bytes = build_flac_bytes_with_streaminfo(
        sample_rate: 44_100,
        channels: 1,
        bit_depth: 16,
        total_samples: 7,
        frame_bytes: frame1 + frame2
      )

      expect(described_class).not_to receive(:read)

      chunks = []
      described_class.stream_read(StringIO.new(bytes), chunk_size: 2) { |chunk| chunks << chunk }

      expect(chunks.map(&:sample_frame_count)).to eq([2, 2, 2, 1])
      expect(chunks.flat_map(&:samples)).to eq([10, 20, 30, 40, 50, 60, 70])
    end
  end
end
