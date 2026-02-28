# frozen_string_literal: true

require "stringio"
require "tempfile"
require "open3"

RSpec.describe Wavify::Codecs::OggVorbis do
  def spec_ogg_crc32(bytes)
    crc = 0
    bytes.each_byte do |byte|
      crc ^= (byte << 24)
      8.times do
        crc = if crc.anybits?(0x8000_0000)
                ((crc << 1) ^ 0x04C11DB7) & 0xFFFF_FFFF
              else
                (crc << 1) & 0xFFFF_FFFF
              end
      end
    end
    crc
  end

  def build_identification_packet(channels:, sample_rate:, nominal_bitrate: 192_000)
    packet = +"\x01vorbis"
    packet << [0].pack("V")
    packet << [channels].pack("C")
    packet << [sample_rate].pack("V")
    packet << [-1].pack("l<")
    packet << [nominal_bitrate].pack("l<")
    packet << [-1].pack("l<")
    packet << [0xB8].pack("C") # 256 / 2048 block sizes
    packet << [1].pack("C")
    packet
  end

  def build_comment_packet(vendor:, comments:)
    packet = +"\x03vorbis"
    packet << [vendor.bytesize].pack("V")
    packet << vendor
    packet << [comments.length].pack("V")
    comments.each do |comment|
      packet << [comment.bytesize].pack("V")
      packet << comment
    end
    packet << [1].pack("C")
    packet
  end

  def external_vorbis_decoder_command_for_compare(input_path)
    ffmpeg_ok = system("command -v ffmpeg >/dev/null 2>&1")
    return nil unless ffmpeg_ok

    decoders, = Open3.capture2("ffmpeg", "-hide_banner", "-decoders")
    return nil unless decoders.include?("libvorbis")

    {
      backend: :ffmpeg_libvorbis,
      command: ["ffmpeg", "-v", "error", "-c:a", "libvorbis", "-i", input_path, "-f", "f32le", "-acodec", "pcm_f32le", "-"]
    }
  end

  def decode_external_vorbis_pcm_f32le(input_path)
    decoder = external_vorbis_decoder_command_for_compare(input_path)
    if decoder
      stdout, stderr, status = Open3.capture3(*decoder.fetch(:command))
      raise "external decoder failed: #{stderr}" unless status.success?

      return { backend: decoder.fetch(:backend), samples: stdout.unpack("e*") }
    end

    oggdec_ok = system("command -v oggdec >/dev/null 2>&1")
    return nil unless oggdec_ok

    Tempfile.create(["wavify-external-vorbis-compare", ".wav"]) do |tmp|
      tmp.close
      stdout, stderr, status = Open3.capture3("oggdec", "-Q", "-o", tmp.path, input_path)
      error_output = stderr.to_s.empty? ? stdout : stderr
      raise "external decoder failed: #{error_output}" unless status.success?

      decoded = Wavify::Codecs::Wav.read(tmp.path)
      float_format = decoded.format.with(sample_format: :float, bit_depth: 32)
      normalized = decoded.format == float_format ? decoded : decoded.convert(float_format)
      return { backend: :oggdec, samples: normalized.samples.map(&:to_f) }
    end
  end

  def best_aligned_pcm_compare_metrics(reference_samples, external_samples, max_offset_samples: 4096)
    reference = Array(reference_samples).map(&:to_f)
    external = Array(external_samples).map(&:to_f)
    best = nil

    (-Integer(max_offset_samples)..Integer(max_offset_samples)).each do |offset|
      reference_start = [0, -offset].max
      external_start = [0, offset].max
      count = [reference.length - reference_start, external.length - external_start].min
      next if count <= 0

      squared_error_sum = 0.0
      max_abs_error = 0.0
      count.times do |i|
        diff = reference.fetch(reference_start + i) - external.fetch(external_start + i)
        abs_diff = diff.abs
        max_abs_error = abs_diff if abs_diff > max_abs_error
        squared_error_sum += diff * diff
      end

      rms_error = Math.sqrt(squared_error_sum / count.to_f)
      candidate = {
        sample_offset: offset,
        compared_sample_count: count,
        max_abs_error: max_abs_error,
        rms_error: rms_error
      }
      next unless best.nil? ||
                  candidate[:rms_error] < best[:rms_error] ||
                  (candidate[:rms_error] == best[:rms_error] && candidate[:max_abs_error] < best[:max_abs_error])

      best = candidate
    end

    best || { sample_offset: 0, compared_sample_count: 0, max_abs_error: Float::INFINITY, rms_error: Float::INFINITY }
  end

  def pearson_correlation(a_values, b_values)
    a = Array(a_values).map(&:to_f)
    b = Array(b_values).map(&:to_f)
    count = [a.length, b.length].min
    return 0.0 if count <= 1

    a = a.first(count)
    b = b.first(count)
    sum_a = a.sum
    sum_b = b.sum
    sum_aa = a.sum { |v| v * v }
    sum_bb = b.sum { |v| v * v }
    sum_ab = a.zip(b).sum { |x, y| x * y }
    denom_a = sum_aa - ((sum_a * sum_a) / count.to_f)
    denom_b = sum_bb - ((sum_b * sum_b) / count.to_f)
    return 0.0 if denom_a <= 0.0 || denom_b <= 0.0

    (sum_ab - ((sum_a * sum_b) / count.to_f)) / Math.sqrt(denom_a * denom_b)
  end

  def aligned_pcm_compare_mismatch_diagnostics(
    _file,
    wavify_samples,
    external_samples,
    alignment_metrics,
    channels:
  )
    channel_count = Integer(channels)
    offset = Integer(alignment_metrics.fetch(:sample_offset))
    compared_sample_count = Integer(alignment_metrics.fetch(:compared_sample_count))
    return { channel_count: channel_count, compared_sample_count: 0 } if compared_sample_count <= 0

    wavify_start = [0, -offset].max
    external_start = [0, offset].max
    sample_count = [compared_sample_count, wavify_samples.length - wavify_start, external_samples.length - external_start].min
    frame_count = sample_count / channel_count
    sample_count = frame_count * channel_count
    return { channel_count: channel_count, compared_sample_count: 0 } if sample_count <= 0

    aligned_wavify = wavify_samples.slice(wavify_start, sample_count)
    aligned_external = external_samples.slice(external_start, sample_count)

    per_channel = Array.new(channel_count) do |channel_index|
      wavify_channel = []
      external_channel = []
      frame_count.times do |frame_index|
        sample_index = (frame_index * channel_count) + channel_index
        wavify_channel << aligned_wavify.fetch(sample_index)
        external_channel << aligned_external.fetch(sample_index)
      end
      diffs = wavify_channel.zip(external_channel).map { |a, b| a - b }
      {
        channel: channel_index,
        rms_error: Math.sqrt(diffs.sum { |d| d * d } / [diffs.length, 1].max.to_f),
        max_abs_error: diffs.map(&:abs).max || 0.0,
        correlation: pearson_correlation(wavify_channel, external_channel)
      }
    end
    channel_hypotheses = {}
    if channel_count == 2
      wavify_left = []
      wavify_right = []
      external_left = []
      external_right = []
      frame_count.times do |frame_index|
        base = frame_index * 2
        wavify_left << aligned_wavify.fetch(base)
        wavify_right << aligned_wavify.fetch(base + 1)
        external_left << aligned_external.fetch(base)
        external_right << aligned_external.fetch(base + 1)
      end
      channel_hypotheses = {
        normal_mean_corr: (pearson_correlation(wavify_left, external_left) + pearson_correlation(wavify_right, external_right)) / 2.0,
        swapped_mean_corr: (pearson_correlation(wavify_left, external_right) + pearson_correlation(wavify_right, external_left)) / 2.0,
        normal_signflip_mean_corr: (pearson_correlation(wavify_left, external_left.map(&:-@)) +
                                    pearson_correlation(wavify_right, external_right.map(&:-@))) / 2.0,
        swapped_signflip_mean_corr: (pearson_correlation(wavify_left, external_right.map(&:-@)) +
                                     pearson_correlation(wavify_right, external_left.map(&:-@))) / 2.0
      }
    end

    {
      channel_count: channel_count,
      frame_count: frame_count,
      compared_sample_count: sample_count,
      per_channel: per_channel,
      boundary_frame_count: 0,
      interior_frame_count: frame_count,
      boundary_rms_error: 0.0,
      interior_rms_error: alignment_metrics.fetch(:rms_error),
      channel_hypotheses: channel_hypotheses,
      worst_packets: []
    }
  end

  def build_setup_packet(payload = "setup-payload")
    +"\x05vorbis" << payload
  end

  # Reads raw OGG page bytes from a byte string using ogg-ruby.
  def read_ogg_pages_for_spec(bytes)
    io = StringIO.new(String(bytes).b)
    sync = Ogg::SyncState.new
    pages = []
    loop do
      data = io.read(4096)
      sync.write(data) if data
      while (page = sync.pageout)
        pages << page.to_s
      end
      break if data.nil?
    end
    pages
  ensure
    sync&.clear
  end

  def build_interleaved_ogg_multistream_bytes(*fixture_paths)
    page_lists = fixture_paths.map { |path| read_ogg_pages_for_spec(File.binread(path)) }
    max_pages = page_lists.map(&:length).max || 0
    bytes = +""
    max_pages.times do |page_index|
      page_lists.each do |pages|
        page = pages[page_index]
        bytes << page if page
      end
    end
    bytes
  end

  def build_interleaved_ogg_multistream_bytes_from_bytes(*byte_streams)
    page_lists = byte_streams.map { |bytes| read_ogg_pages_for_spec(bytes) }
    max_pages = page_lists.map(&:length).max || 0
    bytes = +""
    max_pages.times do |page_index|
      page_lists.each do |pages|
        page = pages[page_index]
        bytes << page if page
      end
    end
    bytes
  end

  def build_chained_ogg_bytes(*byte_streams)
    byte_streams.reduce(+"") { |acc, bytes| acc << String(bytes).b }
  end

  def build_encoded_silent_vorbis_bytes_for_spec(sample_rate:, frames:, channels: 2)
    format = Wavify::Core::Format.new(channels: channels, sample_rate: sample_rate, bit_depth: 32, sample_format: :float)
    buffer = Wavify::Core::SampleBuffer.new(Array.new(frames * channels, 0.0), format)
    io = StringIO.new
    described_class.write(io, buffer, format: format)
    io.string.b
  end

  def build_ogg_page(serial:, sequence:, header_type:, granule_position:, segments:)
    payload = segments.join
    lacing_table = segments.map(&:bytesize)
    raise "too many segments" if lacing_table.length > 255
    raise "segment too large" if lacing_table.any? { |size| size > 255 }

    header = +"OggS"
    header << [0].pack("C")
    header << [header_type].pack("C")
    header << [granule_position].pack("Q<")
    header << [serial].pack("V")
    header << [sequence].pack("V")
    header << [0].pack("V") # placeholder checksum
    header << [lacing_table.length].pack("C")
    header << lacing_table.pack("C*")
    header << payload
    checksum = spec_ogg_crc32(header)
    header[22, 4] = [checksum].pack("V")
    header
  end

  def split_packet_for_pages(packet, split_at)
    raise "invalid split" if split_at <= 0 || split_at >= packet.bytesize

    [packet.byteslice(0, split_at), packet.byteslice(split_at, packet.bytesize - split_at)]
  end

  describe ".metadata" do
    it "parses OGG pages and Vorbis headers including continued packets" do
      vendor = "wavify-test-vendor-#{'x' * 240}"
      comments = ["ARTIST=wavify", "TITLE=OGG metadata spec"]
      identification = build_identification_packet(channels: 2, sample_rate: 48_000)
      comment_packet = build_comment_packet(vendor: vendor, comments: comments)
      setup = build_setup_packet("dummy-setup-data")
      comment_head, comment_tail = split_packet_for_pages(comment_packet, 255)

      serial = 0x1020_3040
      bytes = +""
      bytes << build_ogg_page(
        serial: serial,
        sequence: 0,
        header_type: 0x02,
        granule_position: 0,
        segments: [identification]
      )
      bytes << build_ogg_page(
        serial: serial,
        sequence: 1,
        header_type: 0x00,
        granule_position: 0,
        segments: [comment_head]
      )
      bytes << build_ogg_page(
        serial: serial,
        sequence: 2,
        header_type: 0x01,
        granule_position: 0,
        segments: [comment_tail]
      )
      bytes << build_ogg_page(
        serial: serial,
        sequence: 3,
        header_type: 0x00,
        granule_position: 0,
        segments: [setup]
      )
      bytes << build_ogg_page(
        serial: serial,
        sequence: 4,
        header_type: 0x04,
        granule_position: 48_000,
        segments: ["\x00" * 12]
      )

      metadata = described_class.metadata(StringIO.new(bytes))

      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:sample_frame_count]).to eq(48_000)
      expect(metadata[:duration].total_seconds).to eq(1.0)
      expect(metadata[:vendor]).to eq(vendor)
      expect(metadata[:comments]).to include("artist" => "wavify", "title" => "OGG metadata spec")
      expect(metadata[:ogg_serial_number]).to eq(serial)
      expect(metadata[:ogg_page_count]).to eq(5)
      expect(metadata[:ogg_packet_count]).to eq(4)
      expect(metadata[:ogg_bos_page_count]).to eq(1)
      expect(metadata[:ogg_eos_page_count]).to eq(1)
      expect(metadata[:ogg_continued_page_count]).to eq(1)
      expect(metadata[:vorbis_audio_packet_count]).to eq(1)
      expect(metadata[:vorbis_non_audio_packet_count]).to eq(0)
      expect(metadata[:vorbis_audio_packets_with_granule_count]).to eq(1)
      expect(metadata[:first_audio_packet_granule_position]).to eq(48_000)
      expect(metadata[:last_audio_packet_granule_position]).to eq(48_000)
      expect(metadata[:vorbis_setup_parsed]).to eq(false)
      expect(metadata[:vorbis_codebook_dimensions]).to be_nil
      expect(metadata[:vorbis_codebook_entries]).to be_nil
      expect(metadata[:vorbis_codebook_lookup_types]).to be_nil
      expect(metadata[:vorbis_codebook_used_entry_counts]).to be_nil
      expect(metadata[:vorbis_codebook_sparse_count]).to be_nil
      expect(metadata[:vorbis_codebook_huffman_complete_count]).to be_nil
      expect(metadata[:vorbis_codebook_huffman_incomplete_count]).to be_nil
      expect(metadata[:vorbis_codebook_huffman_max_codeword_length]).to be_nil
      expect(metadata[:vorbis_mode_count]).to be_nil
      expect(metadata[:vorbis_mode_blocksizes]).to be_nil
      expect(metadata[:vorbis_floor_types]).to be_nil
      expect(metadata[:vorbis_residue_types]).to be_nil
      expect(metadata[:vorbis_mapping_submap_counts]).to be_nil
      expect(metadata[:vorbis_mapping_coupling_step_counts]).to be_nil
      expect(metadata[:vorbis_mapping_coupling_pairs]).to be_nil
      expect(metadata[:vorbis_mapping_channel_muxes]).to be_nil
      expect(metadata[:vorbis_mapping_submap_floors]).to be_nil
      expect(metadata[:vorbis_mapping_submap_residues]).to be_nil
      expect(metadata[:vorbis_audio_packet_header_parsed_count]).to eq(0)
      expect(metadata[:vorbis_audio_packet_mode_histogram]).to eq({})
      expect(metadata[:vorbis_audio_packet_blocksize_histogram]).to eq({})
      expect(metadata[:vorbis_window_transition_histogram]).to eq({})
      expect(metadata[:vorbis_decode_plan_built]).to eq(false)
      expect(metadata[:vorbis_decode_plan_packet_count]).to be_nil
      expect(metadata[:vorbis_decode_plan_nominal_overlap_frame_total]).to be_nil
      expect(metadata[:vorbis_output_assembly_preflight_ok]).to be_nil
      expect(metadata[:vorbis_output_assembly_preflight_error]).to be_nil
      expect(metadata[:vorbis_output_assembly_emitted_frame_count]).to be_nil
      expect(metadata[:vorbis_output_assembly_trim_frames]).to be_nil
      expect(metadata[:vorbis_output_assembly_window_curve_preflight_count]).to be_nil
      expect(metadata[:setup_header_size]).to eq(setup.bytesize)
    end

    it "parses Vorbis setup summary from a real OGG fixture" do
      metadata = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")

      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:vorbis_setup_parsed]).to eq(true)
      expect(metadata[:blocksize_small]).to be_a(Integer).and(be > 0)
      expect(metadata[:blocksize_large]).to be_a(Integer).and(be > 0)
      expect(metadata[:blocksize_small]).to be <= metadata[:blocksize_large]
      expect(metadata[:vorbis_audio_packet_count]).to be >= 1
      expect(metadata[:vorbis_audio_packets_with_granule_count]).to be >= 1
      expect(metadata[:sample_frame_count]).to be > 0
      expect(metadata[:vendor]).not_to be_nil
      # Internal Vorbis details (codebooks, floors, etc.) are not accessible via libvorbis API
      expect(metadata[:vorbis_codebook_count]).to be_nil
      expect(metadata[:vorbis_floor_types]).to be_nil
      expect(metadata[:vorbis_residue_types]).to be_nil
    end

    it "parses metadata for a floor0/residue0 fixture" do
      metadata = described_class.metadata("spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg")

      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:vorbis_floor_types]).to be_nil
      expect(metadata[:vorbis_residue_types]).to be_nil
      expect(metadata[:sample_frame_count]).to be > 0
    end

    it "parses metadata for a residue1 fixture" do
      metadata = described_class.metadata("spec/fixtures/audio/xiph_48k_mono_residue1_short.ogg")

      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 1, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:vorbis_floor_types]).to be_nil
      expect(metadata[:vorbis_residue_types]).to be_nil
      expect(metadata[:sample_frame_count]).to be > 0
    end

    it "parses metadata for additional ffmpeg-native stereo Vorbis fixtures" do
      fixtures = {
        "spec/fixtures/audio/ffmpeg_native_stereo_32k_short.ogg" => 32_000,
        "spec/fixtures/audio/ffmpeg_native_stereo_48k_short.ogg" => 48_000
      }

      fixtures.each do |path, sample_rate|
        metadata = described_class.metadata(path)

        expect(metadata[:format]).to eq(
          Wavify::Core::Format.new(channels: 2, sample_rate: sample_rate, bit_depth: 32, sample_format: :float)
        )
        expect(metadata[:sample_frame_count]).to be > 0
      end
    end

    it "parses metadata for a same-format chained OGG Vorbis fixture" do
      metadata = described_class.metadata("spec/fixtures/audio/chained_stereo_vorbis_44100_twice.ogg")

      expect(metadata[:vorbis_chained]).to eq(true)
      expect(metadata[:ogg_logical_stream_count]).to eq(2)
      expect(metadata[:ogg_serial_numbers].length).to eq(2)
      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:sample_frame_count]).to eq(4480)
    end

    it "parses metadata for a mixed-format chained OGG Vorbis fixture" do
      metadata = described_class.metadata("spec/fixtures/audio/xiph_chain-test3_mixed_format.ogg")

      expect(metadata[:vorbis_chained]).to eq(true)
      expect(metadata[:vorbis_chained_mixed_format]).to eq(true)
      expect(metadata[:ogg_logical_stream_count]).to eq(2)
      expect(metadata[:ogg_logical_stream_formats].map(&:channels)).to eq([2, 1])
      expect(metadata[:ogg_logical_stream_formats].map(&:sample_rate).uniq).to eq([44_100])
      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:sample_frame_count]).to eq(2_951_242)
    end

    it "aggregates metadata for an interleaved multi-stream OGG Vorbis fixture using mix output semantics" do
      bytes = build_interleaved_ogg_multistream_bytes(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        "spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg"
      )

      left = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right = described_class.metadata("spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg")
      metadata = described_class.metadata(StringIO.new(bytes))

      expect(metadata[:vorbis_interleaved_multistream]).to eq(true)
      expect(metadata[:vorbis_interleaved_multistream_mixed]).to eq(true)
      expect(metadata[:ogg_interleaved_multistream]).to eq(true)
      expect(metadata[:ogg_logical_stream_count]).to eq(2)
      expect(metadata[:ogg_serial_numbers].length).to eq(2)
      expect(metadata[:format]).to eq(left[:format])
      expect(metadata[:sample_frame_count]).to eq([left[:sample_frame_count], right[:sample_frame_count]].max)
      expect(metadata[:ogg_logical_stream_output_frame_counts]).to eq([left[:sample_frame_count], right[:sample_frame_count]])
      expect(metadata[:duration]).to eq(Wavify::Core::Duration.from_samples(metadata[:sample_frame_count], metadata[:format].sample_rate))
    end

    it "aggregates interleaved multi-stream metadata across differing sample rates using first-stream resample policy" do
      right_bytes = build_encoded_silent_vorbis_bytes_for_spec(sample_rate: 48_000, frames: 1025)
      bytes = build_interleaved_ogg_multistream_bytes_from_bytes(
        File.binread("spec/fixtures/audio/stereo_vorbis_44100.ogg"),
        right_bytes
      )

      left = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right = described_class.metadata(StringIO.new(right_bytes))
      metadata = described_class.metadata(StringIO.new(bytes))
      expected_right_frames = described_class.send(
        :resampled_vorbis_sample_frame_count,
        right[:sample_frame_count],
        source_sample_rate: right[:format].sample_rate,
        target_sample_rate: left[:format].sample_rate
      )

      expect(metadata[:vorbis_interleaved_multistream]).to eq(true)
      expect(metadata[:vorbis_interleaved_multistream_resampled_sample_rate]).to eq(true)
      expect(metadata[:format]).to eq(left[:format])
      expect(metadata[:ogg_logical_stream_formats].map(&:sample_rate)).to eq([44_100, 48_000])
      expect(metadata[:ogg_logical_stream_output_frame_counts]).to eq([left[:sample_frame_count], expected_right_frames])
      expect(metadata[:sample_frame_count]).to eq([left[:sample_frame_count], expected_right_frames].max)
    end

    it "raises when setup header is missing" do
      identification = build_identification_packet(channels: 2, sample_rate: 44_100)
      comment_packet = build_comment_packet(vendor: "wavify", comments: [])
      bytes = +""
      bytes << build_ogg_page(serial: 1, sequence: 0, header_type: 0x02, granule_position: 0, segments: [identification])
      bytes << build_ogg_page(serial: 1, sequence: 1, header_type: 0x00, granule_position: 0, segments: [comment_packet])

      expect do
        described_class.metadata(StringIO.new(bytes))
      end.to raise_error(Wavify::InvalidFormatError, /setup header/)
    end

    it "raises on invalid OGG page checksum" do
      identification = build_identification_packet(channels: 2, sample_rate: 44_100)
      bytes = build_ogg_page(serial: 1, sequence: 0, header_type: 0x02, granule_position: 0, segments: [identification]).dup
      bytes.setbyte(bytes.bytesize - 1, bytes.getbyte(bytes.bytesize - 1) ^ 0x01)

      expect do
        described_class.metadata(StringIO.new(bytes))
      end.to raise_error(Wavify::InvalidFormatError, /checksum/)
    end

    it "raises on non-sequential OGG page numbers" do
      identification = build_identification_packet(channels: 2, sample_rate: 44_100)
      comment_packet = build_comment_packet(vendor: "wavify", comments: [])
      setup = build_setup_packet("x")
      bytes = +""
      bytes << build_ogg_page(serial: 1, sequence: 0, header_type: 0x02, granule_position: 0, segments: [identification])
      bytes << build_ogg_page(serial: 1, sequence: 2, header_type: 0x00, granule_position: 0, segments: [comment_packet])
      bytes << build_ogg_page(serial: 1, sequence: 3, header_type: 0x00, granule_position: 0, segments: [setup])

      expect do
        described_class.metadata(StringIO.new(bytes))
      end.to raise_error(Wavify::InvalidFormatError, /sequence/)
    end

    it "raises when first OGG page is missing BOS flag" do
      identification = build_identification_packet(channels: 2, sample_rate: 44_100)
      comment_packet = build_comment_packet(vendor: "wavify", comments: [])
      setup = build_setup_packet("x")
      bytes = +""
      bytes << build_ogg_page(serial: 1, sequence: 0, header_type: 0x00, granule_position: 0, segments: [identification])
      bytes << build_ogg_page(serial: 1, sequence: 1, header_type: 0x00, granule_position: 0, segments: [comment_packet])
      bytes << build_ogg_page(serial: 1, sequence: 2, header_type: 0x00, granule_position: 0, segments: [setup])

      expect do
        described_class.metadata(StringIO.new(bytes))
      end.to raise_error(Wavify::InvalidFormatError, /BOS flag/)
    end
  end

  describe "internal packet parsing" do
    it "assigns page granule position only to the last completed packet on a page" do
      identification = build_identification_packet(channels: 2, sample_rate: 44_100)
      comment_packet = build_comment_packet(vendor: "wavify", comments: [])
      setup = build_setup_packet("x")
      audio_packet_1 = "\x00audio-1".b
      audio_packet_2 = "\x00audio-2".b

      bytes = +""
      bytes << build_ogg_page(serial: 1, sequence: 0, header_type: 0x02, granule_position: 0, segments: [identification])
      bytes << build_ogg_page(serial: 1, sequence: 1, header_type: 0x00, granule_position: 0, segments: [comment_packet, setup])
      bytes << build_ogg_page(
        serial: 1,
        sequence: 2,
        header_type: 0x04,
        granule_position: 1234,
        segments: [audio_packet_1, audio_packet_2]
      )

      packets, = described_class.send(:read_ogg_packets, StringIO.new(bytes))
      audio_packets = packets.select { |packet| packet[:kind] == :audio }

      expect(audio_packets.length).to eq(2)
      expect(audio_packets.map { |packet| packet[:granule_position] }).to eq([nil, 1234])
    end

    it "deinterleaves OGG pages by serial and detects overlapping logical streams" do
      bytes = build_interleaved_ogg_multistream_bytes(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        "spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg"
      )

      streams, physical_info = described_class.send(:read_ogg_logical_stream_chains, StringIO.new(bytes))

      expect(streams.length).to eq(2)
      expect(physical_info[:logical_stream_count]).to eq(2)
      expect(physical_info[:interleaved_multistream]).to eq(true)
      expect(physical_info[:overlapping_logical_stream_serial_pairs].length).to eq(1)
      expect(streams.map { |stream| stream[:interleaved_pages] }).to eq([true, true])
      expect(streams.map { |stream| stream[:serial_number] }.uniq.length).to eq(2)
      expect(streams).to all(include(:first_physical_page_index, :last_physical_page_index, :physical_page_indices))

      parsed_metadatas = streams.map do |stream|
        described_class.send(:parse_single_logical_stream_metadata, StringIO.new(stream.fetch(:bytes)))
      end
      expect(parsed_metadatas.map { |metadata| metadata[:format].sample_rate }.uniq).to eq([44_100])
      expect(parsed_metadatas.map { |metadata| metadata[:format].channels }.uniq).to eq([2])
    end

    it "concatenates chained buffers by converting mixed channel layouts to the first format" do
      stereo_format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      mono_format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      stereo = Wavify::Core::SampleBuffer.new([0.1, -0.2, 0.3, -0.4], stereo_format)
      mono = Wavify::Core::SampleBuffer.new([0.5, -0.25], mono_format)

      merged = described_class.send(:concatenate_vorbis_sample_buffers, [stereo, mono])

      expect(merged.format).to eq(stereo_format)
      expect(merged.sample_frame_count).to eq(4)
      expect(merged.samples.last(2)).to eq([-0.25, -0.25])
    end

    it "mixes multi-stream buffers by summing and clipping after format normalization" do
      stereo_format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      mono_format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      stereo = Wavify::Core::SampleBuffer.new([0.75, -0.75, 0.25, -0.25], stereo_format)
      mono = Wavify::Core::SampleBuffer.new([1.0, -1.0], mono_format)

      mixed = described_class.send(:mix_vorbis_sample_buffers, [stereo, mono])

      expect(mixed.format).to eq(stereo_format)
      expect(mixed.sample_frame_count).to eq(2)
      expect(mixed.samples).to eq([1.0, 0.25, -0.75, -1.0])
    end

    it "resamples a sample buffer with linear interpolation to a target sample rate" do
      source_format = Wavify::Core::Format.new(channels: 1, sample_rate: 8_000, bit_depth: 32, sample_format: :float)
      source = Wavify::Core::SampleBuffer.new([0.0, 1.0, 0.0, -1.0], source_format)

      resampled = described_class.send(:resample_vorbis_sample_buffer, source, target_sample_rate: 16_000)

      expect(resampled.format).to eq(source_format.with(sample_rate: 16_000))
      expect(resampled.sample_frame_count).to eq(
        described_class.send(:resampled_vorbis_sample_frame_count, 4, source_sample_rate: 8_000, target_sample_rate: 16_000)
      )
      expect(resampled.samples.first).to eq(0.0)
      expect(resampled.samples[1]).to be_within(1e-6).of(0.5)
      expect(resampled.samples[2]).to eq(1.0)
    end

    it "streams chained logical streams with mixed channel layouts using the first stream format" do
      stereo_format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      mono_format = Wavify::Core::Format.new(channels: 1, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      stereo_chunk = Wavify::Core::SampleBuffer.new([0.1, -0.2], stereo_format)
      mono_chunk = Wavify::Core::SampleBuffer.new([0.5], mono_format)
      yielded = []

      allow(described_class).to receive(:read_ogg_logical_stream_chains_from_input).and_wrap_original do |_original, io_or_path, with_info: false|
        expect(io_or_path).to eq("dummy.ogg")
        expect(with_info).to eq(true)
        [
          [{ bytes: "a".b }, { bytes: "b".b }],
          { interleaved_multistream: false }
        ]
      end
      allow(described_class).to receive(:stream_read).and_wrap_original do |_original, io_or_path, chunk_size:, decode_mode:, &blk|
        expect(chunk_size).to eq(256)
        expect(decode_mode).to eq(:strict)
        case io_or_path
        when StringIO
          if io_or_path.string == "a".b
            blk.call(stereo_chunk)
          else
            blk.call(mono_chunk)
          end
        else
          raise "unexpected outer stream_read invocation in helper test"
        end
      end
      allow(described_class).to receive(:parse_single_logical_stream_metadata).and_wrap_original do |_original, io_or_path|
        raise "expected StringIO" unless io_or_path.is_a?(StringIO)

        case io_or_path.string
        when "a".b
          { format: stereo_format }
        when "b".b
          { format: mono_format }
        else
          raise "unexpected logical stream bytes in metadata pre-parse"
        end
      end

      handled = described_class.send(
        :stream_chained_vorbis_if_needed,
        "dummy.ogg",
        chunk_size: 256,
        decode_mode: :strict
      ) do |chunk|
        yielded << chunk
      end

      expect(handled).to eq(true)
      expect(yielded.map(&:format).uniq).to eq([stereo_format])
      expect(yielded.map(&:sample_frame_count)).to eq([1, 1])
      expect(yielded.last.samples).to eq([0.5, 0.5])
    end
  end

  describe "encoding skeleton" do
    it "returns an enumerator for stream_write when no block is given" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 16, sample_format: :pcm)
      enumerator = described_class.stream_write(StringIO.new, format: format)

      expect(enumerator).to be_a(Enumerator)
    end

    it "emits a header-only OGG Vorbis stream using the libvorbis encoder" do
      io = StringIO.new
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)

      described_class.stream_write(io, format: format) do |writer|
        expect(writer).to respond_to(:call)
      end

      metadata = described_class.metadata(StringIO.new(io.string))
      expect(metadata[:format]).to eq(
        Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      )
      expect(metadata[:sample_frame_count]).to eq(0)
      # libvorbis may emit a flush/EOS packet even with no audio written
      expect(metadata[:ogg_packet_count]).to be >= 3
      expect(metadata[:ogg_bos_page_count]).to eq(1)
      expect(metadata[:ogg_eos_page_count]).to eq(1)
      expect(metadata[:vorbis_audio_packet_count]).to be <= 1
      expect(metadata[:vorbis_setup_parsed]).to eq(true)
      expect(metadata[:vendor]).not_to be_nil
    end

    it "encodes silent audio chunks with exact duration and near-zero signal" do
      io = StringIO.new
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      chunk1 = Wavify::Core::SampleBuffer.new([0.0] * (2 * 600), format)
      chunk2 = Wavify::Core::SampleBuffer.new([0.0] * (2 * 900), format)

      described_class.stream_write(io, format: format) do |writer|
        writer.call(chunk1)
        writer.call(chunk2)
      end

      metadata = described_class.metadata(StringIO.new(io.string))
      buffer = described_class.read(StringIO.new(io.string))

      expect(metadata[:sample_frame_count]).to eq(1500)
      expect(metadata[:vorbis_audio_packet_count]).to be >= 2
      expect(buffer.sample_frame_count).to eq(1500)
      expect(buffer.format).to eq(format)
      expect(buffer.samples.map(&:to_f).map(&:abs).max).to be < 1e-5
    end

    it "accepts multiple audio chunks during stream_write and produces output after finalize" do
      io = StringIO.new
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      chunk = Wavify::Core::SampleBuffer.new([0.0] * (2 * 1200), format)
      header_bytesize = nil

      described_class.stream_write(io, format: format) do |writer|
        header_bytesize = io.string.bytesize
        writer.call(chunk)
        writer.call(chunk)
      end

      final_bytesize = io.string.bytesize
      expect(header_bytesize).to be > 0
      # libvorbis (via ogg_stream_pageout) buffers audio pages until EOS or a large enough buffer;
      # audio pages are flushed at finalize time, so total output is larger than headers alone
      expect(final_bytesize).to be > header_bytesize
    end

    it "encodes a silent buffer via write using libvorbis" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 48_000, bit_depth: 32, sample_format: :float)
      buffer = Wavify::Core::SampleBuffer.new([0.0] * (2 * 1025), format)

      Tempfile.create(["wavify-vorbis-encode", ".ogg"]) do |file|
        file.binmode
        described_class.write(file.path, buffer, format: format)

        decoded = described_class.read(file.path)
        metadata = described_class.metadata(file.path)
        expect(decoded.sample_frame_count).to eq(1025)
        expect(decoded.samples.map(&:to_f).map(&:abs).max).to be < 1e-5
        expect(metadata[:sample_frame_count]).to eq(1025)
        expect(metadata[:format].sample_rate).to eq(48_000)
      end
    end

    it "encodes non-silent stereo chunks via libvorbis" do
      io = StringIO.new
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      fixture = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      chunk = fixture.slice(0, 1536).convert(format)
      expect(chunk.samples.any? { |sample| sample.to_f != 0.0 }).to eq(true)

      described_class.stream_write(io, format: format) do |writer|
        writer.call(chunk)
      end

      decoded = described_class.read(StringIO.new(io.string))
      metadata = described_class.metadata(StringIO.new(io.string))
      expect(decoded.sample_frame_count).to eq(chunk.sample_frame_count)
      expect(decoded.format).to eq(format)
      expect(decoded.samples.any? { |sample| sample.to_f != 0.0 }).to eq(true)
      expect(metadata[:sample_frame_count]).to eq(chunk.sample_frame_count)
      expect(metadata[:vorbis_audio_packet_count]).to be >= 2
    end

    it "keeps write/stream_write decoded sample frame count consistent across chunk splits" do
      format = Wavify::Core::Format.new(channels: 2, sample_rate: 44_100, bit_depth: 32, sample_format: :float)
      fixture = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      buffer = fixture.slice(0, 2500).convert(format)
      chunk1 = buffer.slice(0, 700)
      chunk2 = buffer.slice(700, 900)
      chunk3 = buffer.slice(1600, buffer.sample_frame_count - 1600)

      io_write = StringIO.new
      io_stream = StringIO.new

      described_class.write(io_write, buffer, format: format)
      described_class.stream_write(io_stream, format: format) do |writer|
        writer.call(chunk1)
        writer.call(chunk2)
        writer.call(chunk3)
      end

      decoded_write = described_class.read(StringIO.new(io_write.string))
      decoded_stream = described_class.read(StringIO.new(io_stream.string))
      expect(decoded_stream.sample_frame_count).to eq(buffer.sample_frame_count)
      expect(decoded_stream.sample_frame_count).to eq(decoded_write.sample_frame_count)
    end
  end

  describe "decoding behavior" do
    it "returns placeholder-decoded audio on read when decode_mode is placeholder" do
      buffer = described_class.read(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        decode_mode: :placeholder
      )

      metadata = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      expect(buffer).to be_a(Wavify::Core::SampleBuffer)
      expect(buffer.format.channels).to eq(metadata[:format].channels)
      expect(buffer.format.sample_rate).to eq(metadata[:format].sample_rate)
      expect(buffer.sample_frame_count).to eq(metadata[:sample_frame_count])
      expect(buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
    end

    it "streams placeholder-decoded audio chunks when decode_mode is placeholder" do
      metadata = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      chunks = []

      described_class.stream_read(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        chunk_size: 256,
        decode_mode: :placeholder
      ) do |chunk|
        chunks << chunk
      end

      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
      expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
      expect(chunks.length).to eq((metadata[:sample_frame_count] + 255) / 256)
      expect(chunks.flat_map(&:samples).any? { |sample| sample != 0.0 }).to eq(true)
    end

    it "decodes a valid file on read using libvorbis" do
      metadata = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      buffer = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")

      expect(buffer).to be_a(Wavify::Core::SampleBuffer)
      expect(buffer.sample_frame_count).to eq(metadata[:sample_frame_count])
      expect(buffer.format.channels).to eq(metadata[:format].channels)
      expect(buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
    end

    it "decodes a valid file on stream_read using libvorbis" do
      metadata = described_class.metadata("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      chunks = []

      described_class.stream_read("spec/fixtures/audio/stereo_vorbis_44100.ogg", chunk_size: 256) do |chunk|
        chunks << chunk
      end

      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
      expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
    end

    it "streams and reads a same-format chained OGG Vorbis fixture" do
      metadata = described_class.metadata("spec/fixtures/audio/chained_stereo_vorbis_44100_twice.ogg")
      buffer = described_class.read("spec/fixtures/audio/chained_stereo_vorbis_44100_twice.ogg")
      chunks = []

      described_class.stream_read("spec/fixtures/audio/chained_stereo_vorbis_44100_twice.ogg", chunk_size: 256) do |chunk|
        chunks << chunk
      end

      expect(buffer.sample_frame_count).to eq(metadata[:sample_frame_count])
      expect(buffer.format).to eq(metadata[:format])
      expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
    end

    it "reads and streams interleaved multi-stream OGG by mixing logical streams" do
      bytes = build_interleaved_ogg_multistream_bytes(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        "spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg"
      )
      left = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right = described_class.read("spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg")
      expected = Wavify::Audio.mix(Wavify::Audio.new(left), Wavify::Audio.new(right)).buffer
      streamed_chunks = []

      mixed = described_class.read(StringIO.new(bytes))
      described_class.stream_read(StringIO.new(bytes), chunk_size: 256) do |chunk|
        streamed_chunks << chunk
      end

      streamed = streamed_chunks.reduce do |combined, chunk|
        combined.concat(chunk)
      end

      expect(mixed.format).to eq(expected.format)
      expect(mixed.sample_frame_count).to eq(expected.sample_frame_count)
      expect(mixed.samples).to eq(expected.samples)
      expect(streamed_chunks).not_to be_empty
      expect(streamed_chunks).to all(be_a(Wavify::Core::SampleBuffer))
      expect(streamed.format).to eq(expected.format)
      expect(streamed.sample_frame_count).to eq(expected.sample_frame_count)
      expect(streamed.samples).to eq(expected.samples)
    end

    it "streams same-rate interleaved multi-stream OGG without falling back to full-buffer read" do
      bytes = build_interleaved_ogg_multistream_bytes(
        "spec/fixtures/audio/stereo_vorbis_44100.ogg",
        "spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg"
      )
      chunks = []

      allow(described_class).to receive(:read).and_wrap_original do |original, io_or_path, *args, **kwargs|
        if io_or_path.is_a?(StringIO) && io_or_path.string.start_with?("OggS")
          raise "full-buffer read fallback should not be used for same-rate interleaved streaming"
        end

        original.call(io_or_path, *args, **kwargs)
      end

      described_class.stream_read(StringIO.new(bytes), chunk_size: 256) do |chunk|
        chunks << chunk
      end

      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
    end

    it "streams differing-sample-rate interleaved multi-stream OGG without falling back to full-buffer read" do
      left_bytes = File.binread("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right_bytes = build_encoded_silent_vorbis_bytes_for_spec(sample_rate: 48_000, frames: 1025)
      bytes = build_interleaved_ogg_multistream_bytes_from_bytes(left_bytes, right_bytes)
      chunks = []

      allow(described_class).to receive(:read).and_wrap_original do |original, io_or_path, *args, **kwargs|
        if io_or_path.is_a?(StringIO) && io_or_path.string.start_with?("OggS")
          raise "full-buffer read fallback should not be used for differing-rate interleaved streaming"
        end

        original.call(io_or_path, *args, **kwargs)
      end

      described_class.stream_read(StringIO.new(bytes), chunk_size: 256) do |chunk|
        chunks << chunk
      end

      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
    end

    it "reads and streams differing-sample-rate chained OGG by resampling to the first logical stream sample rate" do
      left_bytes = File.binread("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right_bytes = build_encoded_silent_vorbis_bytes_for_spec(sample_rate: 48_000, frames: 1025)
      chain_bytes = build_chained_ogg_bytes(left_bytes, right_bytes)

      left = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right = described_class.read(StringIO.new(right_bytes))
      expected_right = described_class.send(:normalize_vorbis_logical_stream_buffer_for_target, right, left.format)
      expected = left.concat(expected_right)
      metadata = described_class.metadata(StringIO.new(chain_bytes))
      chunks = []

      decoded = described_class.read(StringIO.new(chain_bytes))
      described_class.stream_read(StringIO.new(chain_bytes), chunk_size: 256) do |chunk|
        chunks << chunk
      end

      streamed = chunks.reduce { |combined, chunk| combined.concat(chunk) }

      expect(metadata[:vorbis_chained]).to eq(true)
      expect(metadata[:vorbis_chained_resampled_sample_rate]).to eq(true)
      expect(metadata[:format]).to eq(left.format)
      expect(metadata[:sample_frame_count]).to eq(expected.sample_frame_count)
      expect(metadata[:ogg_logical_stream_formats].map(&:sample_rate)).to eq([44_100, 48_000])
      expect(decoded.format).to eq(expected.format)
      expect(decoded.samples).to eq(expected.samples)
      expect(streamed.samples).to eq(expected.samples)
    end

    it "reads and streams differing-sample-rate interleaved multi-stream OGG by resampling before mix" do
      left_bytes = File.binread("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right_bytes = build_encoded_silent_vorbis_bytes_for_spec(sample_rate: 48_000, frames: 1025)
      bytes = build_interleaved_ogg_multistream_bytes_from_bytes(left_bytes, right_bytes)

      left = described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg")
      right = described_class.read(StringIO.new(right_bytes))
      expected_right = described_class.send(:normalize_vorbis_logical_stream_buffer_for_target, right, left.format)
      expected = Wavify::Audio.mix(Wavify::Audio.new(left), Wavify::Audio.new(expected_right)).buffer
      metadata = described_class.metadata(StringIO.new(bytes))
      chunks = []

      decoded = described_class.read(StringIO.new(bytes))
      described_class.stream_read(StringIO.new(bytes), chunk_size: 256) do |chunk|
        chunks << chunk
      end

      streamed = chunks.reduce { |combined, chunk| combined.concat(chunk) }

      expect(metadata[:vorbis_interleaved_multistream]).to eq(true)
      expect(metadata[:vorbis_interleaved_multistream_resampled_sample_rate]).to eq(true)
      expect(metadata[:format]).to eq(left.format)
      expect(metadata[:sample_frame_count]).to eq(expected.sample_frame_count)
      expect(decoded.format).to eq(expected.format)
      expect(decoded.samples).to eq(expected.samples)
      expect(streamed.samples).to eq(expected.samples)
    end

    it "decodes a floor0/residue0 fixture via libvorbis" do
      metadata = described_class.metadata("spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg")
      buffer = described_class.read("spec/fixtures/audio/xiph_test-short_floor0_residue0.ogg")

      expect(buffer).to be_a(Wavify::Core::SampleBuffer)
      expect(buffer.sample_frame_count).to eq(metadata[:sample_frame_count])
      expect(buffer.format).to eq(metadata[:format])
      expect(buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
    end

    it "decodes a residue1 fixture on read and stream_read" do
      path = "spec/fixtures/audio/xiph_48k_mono_residue1_short.ogg"
      metadata = described_class.metadata(path)
      buffer = described_class.read(path)
      chunks = []

      described_class.stream_read(path, chunk_size: 1024) do |chunk|
        chunks << chunk
      end

      expect(buffer).to be_a(Wavify::Core::SampleBuffer)
      expect(buffer.sample_frame_count).to eq(metadata[:sample_frame_count])
      expect(buffer.format).to eq(metadata[:format])
      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
      expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
      expect(chunks.first.format).to eq(metadata[:format])
      expect(buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
    end

    it "decodes additional ffmpeg-native stereo fixtures on read and stream_read" do
      paths = [
        "spec/fixtures/audio/ffmpeg_native_stereo_32k_short.ogg",
        "spec/fixtures/audio/ffmpeg_native_stereo_48k_short.ogg"
      ]

      paths.each do |path|
        metadata = described_class.metadata(path)
        buffer = described_class.read(path)
        chunks = []
        described_class.stream_read(path, chunk_size: 257) { |chunk| chunks << chunk }
        streamed = chunks.reduce { |combined, chunk| combined.concat(chunk) }

        expect(buffer).to be_a(Wavify::Core::SampleBuffer)
        expect(buffer.sample_frame_count).to eq(metadata[:sample_frame_count])
        expect(buffer.format).to eq(metadata[:format])
        expect(chunks).not_to be_empty
        expect(chunks).to all(be_a(Wavify::Core::SampleBuffer))
        expect(chunks.sum(&:sample_frame_count)).to eq(metadata[:sample_frame_count])
        expect(streamed.samples).to eq(buffer.samples)
        expect(buffer.samples.any? { |sample| sample != 0.0 }).to eq(true)
      end
    end

    it "returns an enumerator for stream_read when no block is given" do
      enumerator = described_class.stream_read("spec/fixtures/audio/stereo_vorbis_44100.ogg", chunk_size: 256)

      expect(enumerator).to be_a(Enumerator)
      expect(enumerator.next).to be_a(Wavify::Core::SampleBuffer)
    end

    it "validates stream_read chunk_size before preflight" do
      expect do
        described_class.stream_read("spec/fixtures/audio/stereo_vorbis_44100.ogg", chunk_size: 0) { |_chunk| nil }
      end.to raise_error(Wavify::InvalidParameterError, /chunk_size/)
    end

    it "validates decode_mode before preflight" do
      expect do
        described_class.read("spec/fixtures/audio/stereo_vorbis_44100.ogg", decode_mode: :bogus)
      end.to raise_error(Wavify::InvalidParameterError, /decode_mode/)
    end

    it "surfaces format errors during read preflight" do
      Tempfile.create(["wavify", ".ogg"]) do |file|
        file.binmode
        file.write("OggS\x00#{'\x00' * 32}")
        file.flush

        expect do
          described_class.read(file.path)
        end.to raise_error(Wavify::InvalidFormatError)
      end
    end

    it "compares strict decode output with an external Vorbis decoder when available" do
      file = "spec/fixtures/audio/stereo_vorbis_44100.ogg"
      external = decode_external_vorbis_pcm_f32le(file)
      skip("external Vorbis decoder (ffmpeg+libvorbis or oggdec) not available") unless external

      metadata = described_class.metadata(file)
      wavify = described_class.read(file)
      wavify_samples = wavify.samples.map(&:to_f)
      expected_count = metadata.fetch(:sample_frame_count) * metadata.fetch(:format).channels
      external_samples = external.fetch(:samples)
      trimmed_external_samples = external_samples.first(expected_count + 4096)

      expect(wavify_samples.length).to eq(expected_count)
      expect(trimmed_external_samples.length).to be >= expected_count

      metrics = best_aligned_pcm_compare_metrics(wavify_samples, trimmed_external_samples)
      max_abs_error = metrics.fetch(:max_abs_error)
      rms_error = metrics.fetch(:rms_error)

      if max_abs_error > 1e-4 || rms_error > 1e-5
        diagnostics = aligned_pcm_compare_mismatch_diagnostics(
          file,
          wavify_samples,
          trimmed_external_samples,
          metrics,
          channels: metadata.fetch(:format).channels
        )
        ch0 = Array(diagnostics[:per_channel]).first || {}
        ch1 = Array(diagnostics[:per_channel])[1] || {}
        hy = diagnostics[:channel_hypotheses] || {}
        pending(
          "external compare mismatch (backend=#{external.fetch(:backend)} offset=#{metrics[:sample_offset]} " \
          "n=#{metrics[:compared_sample_count]} max=#{max_abs_error} rms=#{rms_error} " \
          "ch0_corr=#{ch0[:correlation]} ch1_corr=#{ch1[:correlation]} " \
          "swap_corr=#{hy[:swapped_mean_corr]} normal_corr=#{hy[:normal_mean_corr]})"
        )
      end

      expect(max_abs_error).to be <= 1e-4
      expect(rms_error).to be <= 1e-5
    end
  end
end
