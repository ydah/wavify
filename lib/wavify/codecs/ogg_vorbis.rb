# frozen_string_literal: true

require "stringio"
require "vorbis"

module Wavify
  module Codecs
    # OGG Vorbis codec backed by libogg (ogg-ruby) and libvorbis (vorbis-ruby).
    #
    # Container demuxing uses {Ogg::SyncState} and {Ogg::StreamState}. Audio
    # decode uses libvorbis synthesis functions via {Vorbis::Native}. Audio
    # encode uses {Vorbis::Encoder}.
    #
    # Sequential chained Vorbis logical streams are concatenated (and
    # resampled to the first logical stream sample rate when rates differ).
    # Interleaved multi-stream OGG logical streams are mixed with clipping.
    class OggVorbis < Base
      # Recognized filename extensions.
      EXTENSIONS = %w[.ogg .oga].freeze

      VORBIS_SIGNATURE = "vorbis" # :nodoc:
      IDENTIFICATION_HEADER_TYPE = 0x01 # :nodoc:
      COMMENT_HEADER_TYPE = 0x03 # :nodoc:
      SETUP_HEADER_TYPE = 0x05 # :nodoc:
      GRANULE_POSITION_UNKNOWN = 0xFFFF_FFFF_FFFF_FFFF # :nodoc:
      VORBIS_ENCODE_DEFAULT_QUALITY = 0.4 # :nodoc:

      class << self
        # @param io_or_path [String, IO]
        # @return [Boolean]
        def can_read?(io_or_path)
          return true if io_or_path.is_a?(String) && EXTENSIONS.include?(File.extname(io_or_path).downcase)
          return false unless io_or_path.respond_to?(:read)

          magic = io_or_path.read(4)
          io_or_path.rewind if io_or_path.respond_to?(:rewind)
          magic == "OggS"
        end

        # Reads OGG Vorbis audio.
        #
        # @note Supports full Vorbis decode via libvorbis. Sequential chained
        #   OGG logical streams are concatenated and normalized to the first
        #   logical stream format (including resampling). Interleaved
        #   multi-stream OGG logical streams are mixed.
        #   `decode_mode:` is accepted for API compatibility but has no
        #   effect; libvorbis always performs full decode.
        def read(io_or_path, format: nil, decode_mode: :strict)
          raise InvalidParameterError, "decode_mode must be :strict or :placeholder, got #{decode_mode.inspect}" unless %i[strict
                                                                                                                           placeholder].include?(decode_mode)

          if (chained_decoded = decode_chained_vorbis_read_if_needed(io_or_path, decode_mode: decode_mode, target_format: format))
            return chained_decoded
          end

          decode_context = build_vorbis_decode_context(io_or_path)
          decoded = run_vorbis_decode_pipeline(decode_context)
          return decoded unless format

          decoded.convert(format)
        end

        # Writes OGG Vorbis audio.
        def write(io_or_path, sample_buffer, format:)
          raise InvalidParameterError, "sample_buffer must be Core::SampleBuffer" unless sample_buffer.is_a?(Core::SampleBuffer)

          stream_write(io_or_path, format: format) do |writer|
            writer.call(sample_buffer)
          end
        end

        # Streams OGG Vorbis audio decoding.
        #
        # @note Supports full Vorbis decode via libvorbis. Sequential chained
        #   OGG logical streams are concatenated and normalized to the first
        #   logical stream format during streaming (including resampling).
        #   Interleaved multi-stream OGG logical streams are mixed.
        #   `decode_mode:` is accepted for API compatibility but has no effect.
        def stream_read(io_or_path, chunk_size: 4096, decode_mode: :strict, &block)
          return enum_for(__method__, io_or_path, chunk_size: chunk_size, decode_mode: decode_mode) unless block_given?
          raise InvalidParameterError, "chunk_size must be a positive Integer" unless chunk_size.is_a?(Integer) && chunk_size.positive?
          raise InvalidParameterError, "decode_mode must be :strict or :placeholder, got #{decode_mode.inspect}" unless %i[strict
                                                                                                                           placeholder].include?(decode_mode)

          return nil if stream_chained_vorbis_if_needed(io_or_path, chunk_size: chunk_size, decode_mode: decode_mode, &block)

          decode_context = build_vorbis_decode_context(io_or_path)
          run_vorbis_decode_pipeline(decode_context, streaming: true, chunk_size: chunk_size, &block)
        end

        # Streams OGG Vorbis audio encoding via {Vorbis::Encoder}.
        #
        # @note Encodes using libvorbis at the default VBR quality level.
        #   Accepts any channel count and sample rate supported by libvorbis.
        def stream_write(io_or_path, format:)
          return enum_for(__method__, io_or_path, format: format) unless block_given?
          raise InvalidParameterError, "format must be Core::Format" unless format.is_a?(Core::Format)
          raise InvalidParameterError, "Vorbis encode requires positive channel count" unless format.channels.to_i.positive?
          raise InvalidParameterError, "Vorbis encode requires positive sample_rate" unless format.sample_rate.to_i.positive?

          target_format = Core::Format.new(
            channels: format.channels,
            sample_rate: format.sample_rate,
            bit_depth: 32,
            sample_format: :float
          )

          io, close_io = open_output(io_or_path)
          io.rewind if io.respond_to?(:rewind)
          io.truncate(0) if io.respond_to?(:truncate)

          encoder = Vorbis::Encoder.new(
            channels: target_format.channels,
            rate: target_format.sample_rate,
            quality: VORBIS_ENCODE_DEFAULT_QUALITY
          )

          encoder.write_headers { |page_bytes| io.write(page_bytes) }

          writer = lambda do |chunk|
            raise InvalidParameterError, "stream chunk must be Core::SampleBuffer" unless chunk.is_a?(Core::SampleBuffer)

            buffer = chunk.format == target_format ? chunk : chunk.convert(target_format)
            next nil if buffer.sample_frame_count.zero?

            channels_data = Array.new(target_format.channels) { [] }
            buffer.samples.each_slice(target_format.channels) do |frame|
              frame.each_with_index { |sample, ch| channels_data[ch] << sample.to_f }
            end
            encoder.encode(channels_data) { |page_bytes| io.write(page_bytes) }
          end

          yield writer

          encoder.finish { |page_bytes| io.write(page_bytes) }
          encoder.close
          io.flush if io.respond_to?(:flush)
          io.rewind if io.respond_to?(:rewind)
          io_or_path
        rescue StandardError
          begin
            encoder&.close
          rescue StandardError
            nil
          end
          raise
        ensure
          io.close if close_io && io
        end

        # Parses OGG/Vorbis headers and returns metadata without audio decode.
        #
        # @param io_or_path [String, IO]
        # @return [Hash]
        def metadata(io_or_path)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)
          chained_streams, physical_ogg_info = read_ogg_logical_stream_chains(io)

          if chained_streams.length > 1
            chain_metadatas = chained_streams.map do |stream|
              parse_single_logical_stream_metadata(StringIO.new(stream.fetch(:bytes)))
            end
            if physical_ogg_info[:interleaved_multistream]
              return merge_interleaved_vorbis_metadata(chain_metadatas, chained_streams, physical_ogg_info)
            end

            return merge_chained_vorbis_metadata(chain_metadatas, chained_streams)
          end

          parse_single_logical_stream_metadata(StringIO.new(chained_streams.fetch(0).fetch(:bytes)))
        ensure
          io.close if close_io && io
        end

        private

        # ---------------------------------------------------------------------------
        # OGG container reading (using ogg-ruby)
        # ---------------------------------------------------------------------------

        def read_ogg_logical_stream_chains_from_input(io_or_path, with_info: false)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          chains, physical_info = read_ogg_logical_stream_chains(io)
          with_info ? [chains, physical_info] : chains
        ensure
          io.close if close_io && io
        end

        def read_ogg_logical_stream_chains(io)
          io.rewind
          sync = Ogg::SyncState.new
          streams_by_serial = {}
          total_page_count = 0
          total_bos_page_count = 0
          total_eos_page_count = 0
          total_continued_page_count = 0
          physical_page_index = 0

          loop do
            data = io.read(4096)
            sync.write(data) if data

            while (page = sync.pageout)
              sn = page.serialno
              bos = page.bos?
              eos = page.eos?
              continued = page.continued?

              raise InvalidFormatError, "first OGG page must have BOS flag" if physical_page_index.zero? && !bos

              stream = streams_by_serial[sn]
              if stream.nil?
                raise InvalidFormatError, "first page of OGG logical stream must have BOS flag" unless bos

                stream = {
                  serial_number: sn,
                  bytes: +"",
                  page_count: 0,
                  bos_page_count: 0,
                  eos_page_count: 0,
                  continued_page_count: 0,
                  eos_seen: false,
                  first_physical_page_index: physical_page_index,
                  last_physical_page_index: physical_page_index,
                  physical_page_indices: []
                }
                streams_by_serial[sn] = stream
              elsif stream[:eos_seen]
                raise InvalidFormatError, "unexpected OGG page after EOS in logical stream"
              end

              raise InvalidFormatError, "unexpected BOS page in OGG logical stream" if stream[:page_count].positive? && bos

              stream[:bytes] << page.to_s
              stream[:page_count] += 1
              stream[:bos_page_count] += 1 if bos
              stream[:eos_page_count] += 1 if eos
              stream[:continued_page_count] += 1 if continued
              stream[:eos_seen] = true if eos
              stream[:last_physical_page_index] = physical_page_index
              stream[:physical_page_indices] << physical_page_index

              total_page_count += 1
              total_bos_page_count += 1 if bos
              total_eos_page_count += 1 if eos
              total_continued_page_count += 1 if continued
              physical_page_index += 1
            end

            break if data.nil?
          end

          streams = streams_by_serial.values.sort_by { |s| s[:first_physical_page_index] }
          raise InvalidFormatError, "empty OGG bitstream" if streams.empty?

          overlapping_pairs = []
          per_stream_overlap = {}
          streams.each_with_index do |left, left_index|
            streams.each_with_index do |right, right_index|
              next if right_index <= left_index

              overlaps = left[:first_physical_page_index] <= right[:last_physical_page_index] &&
                         right[:first_physical_page_index] <= left[:last_physical_page_index]
              next unless overlaps

              left_serial = left[:serial_number]
              right_serial = right[:serial_number]
              overlapping_pairs << [left_serial, right_serial]
              per_stream_overlap[left_serial] = true
              per_stream_overlap[right_serial] = true
            end
          end

          result_streams = streams.map do |stream|
            stream.merge(
              bytes: stream[:bytes].dup.freeze,
              interleaved_pages: per_stream_overlap.fetch(stream[:serial_number], false)
            ).freeze
          end

          [
            result_streams,
            {
              page_count: total_page_count,
              bos_page_count: total_bos_page_count,
              eos_page_count: total_eos_page_count,
              continued_page_count: total_continued_page_count,
              logical_stream_count: streams.length,
              interleaved_multistream: !overlapping_pairs.empty?,
              overlapping_logical_stream_serial_pairs: overlapping_pairs
            }
          ]
        rescue Ogg::CorruptDataError, Ogg::SyncCorruptDataError => e
          raise InvalidFormatError, "OGG data corrupt or invalid checksum: #{e.message}"
        rescue Ogg::StreamCorruptDataError => e
          raise InvalidFormatError, "OGG stream sequence error: #{e.message}"
        ensure
          sync&.clear
        end

        # Reads OGG packets from a single logical stream IO using ogg-ruby.
        #
        # Returns [packets, ogg_info] where packets is an Array of Hashes with
        # :data, :kind, :granule_position keys, and ogg_info is a Hash with
        # page-level statistics.
        def read_ogg_packets(io)
          io.rewind
          sync = Ogg::SyncState.new
          stream_state = nil
          serial_number = nil
          page_count = 0
          bos_page_count = 0
          eos_page_count = 0
          continued_page_count = 0
          max_granule_position = nil
          packets = []

          loop do
            data = io.read(4096)
            sync.write(data) if data

            while (page = sync.pageout)
              sn = page.serialno
              if serial_number && sn != serial_number
                raise UnsupportedFormatError,
                      "multi-stream OGG containers must be split before packet reading"
              end
              raise InvalidFormatError, "first OGG page must have BOS flag" if page_count.zero? && !page.bos?

              serial_number ||= sn
              stream_state ||= Ogg::StreamState.new(sn)
              stream_state.pagein(page)

              bos_page_count += 1 if page.bos?
              eos_page_count += 1 if page.eos?
              continued_page_count += 1 if page.continued?
              page_count += 1

              while (packet = stream_state.packetout)
                granulepos = packet.granulepos
                is_unknown = (granulepos == -1)
                resolved_granule = is_unknown ? nil : granulepos
                packets << {
                  data: packet.data,
                  bos: packet.bos?,
                  eos: packet.eos?,
                  packetno: packet.packetno,
                  kind: classify_vorbis_packet(packet.data),
                  granule_position: resolved_granule
                }
                max_granule_position = [max_granule_position || 0, granulepos].max unless is_unknown
              end
            end

            break if data.nil?
          end

          [
            packets,
            {
              serial_number: serial_number,
              page_count: page_count,
              max_granule_position: max_granule_position,
              bos_page_count: bos_page_count,
              eos_page_count: eos_page_count,
              continued_page_count: continued_page_count
            }
          ]
        rescue Ogg::CorruptDataError, Ogg::SyncCorruptDataError => e
          raise InvalidFormatError, "OGG data corrupt or invalid checksum: #{e.message}"
        rescue Ogg::StreamCorruptDataError => e
          raise InvalidFormatError, "OGG stream sequence error: #{e.message}"
        ensure
          stream_state&.clear
          sync&.clear
        end

        # ---------------------------------------------------------------------------
        # Vorbis decode (using Vorbis::Native synthesis functions)
        # ---------------------------------------------------------------------------

        def build_vorbis_decode_context(io_or_path)
          io, close_io = open_input(io_or_path)
          ensure_seekable!(io)

          packet_entries, ogg_info = read_ogg_packets(io)
          raise InvalidFormatError, "missing Vorbis identification header" if packet_entries[0].nil?
          raise InvalidFormatError, "missing Vorbis comment header" if packet_entries[1].nil?
          raise InvalidFormatError, "missing Vorbis setup header" if packet_entries[2].nil?

          info_ptr = FFI::MemoryPointer.new(Vorbis::Native::VorbisInfo.size)
          comment_ptr = FFI::MemoryPointer.new(Vorbis::Native::VorbisComment.size)
          Vorbis::Native.vorbis_info_init(info_ptr)
          Vorbis::Native.vorbis_comment_init(comment_ptr)

          packet_entries.first(3).each_with_index do |entry, idx|
            pkt = Ogg::Packet.new(
              data: entry.fetch(:data),
              bos: entry.fetch(:bos, idx.zero?),
              eos: entry.fetch(:eos, false),
              packetno: entry.fetch(:packetno, idx)
            )
            result = Vorbis::Native.vorbis_synthesis_headerin(info_ptr, comment_ptr, pkt.native)
            raise InvalidFormatError, "Vorbis header parse failed (code #{result})" unless result.zero?
          end

          vinfo = Vorbis::Native::VorbisInfo.new(info_ptr)
          channels = vinfo[:channels]
          sample_rate = vinfo[:rate]

          audio_packets = packet_entries.drop(3).select { |e| e.fetch(:kind) == :audio }
          raise InvalidFormatError, "OGG Vorbis stream does not contain audio packets" if audio_packets.empty?

          format = Core::Format.new(channels: channels, sample_rate: sample_rate, bit_depth: 32, sample_format: :float)

          {
            format: format,
            channels: channels,
            sample_rate: sample_rate,
            audio_packets: audio_packets,
            sample_frame_count: ogg_info[:max_granule_position],
            info_ptr: info_ptr,
            comment_ptr: comment_ptr
          }
        ensure
          io.close if close_io && io
        end

        def run_vorbis_decode_pipeline(decode_context, streaming: false, chunk_size: nil, &block)
          info_ptr = decode_context.fetch(:info_ptr)
          comment_ptr = decode_context.fetch(:comment_ptr)
          audio_packets = decode_context.fetch(:audio_packets)
          channels = decode_context.fetch(:channels)
          max_granule = decode_context.fetch(:sample_frame_count)
          format = decode_context.fetch(:format)

          dsp_ptr = FFI::MemoryPointer.new(Vorbis::Native::VorbisDspState.size)
          block_ptr = FFI::MemoryPointer.new(Vorbis::Native::VorbisBlock.size)
          pcm_pp = FFI::MemoryPointer.new(:pointer)
          dsp_initialized = false
          block_initialized = false

          result = Vorbis::Native.vorbis_synthesis_init(dsp_ptr, info_ptr)
          raise InvalidFormatError, "Vorbis synthesis init failed (#{result})" unless result.zero?

          dsp_initialized = true

          result = Vorbis::Native.vorbis_block_init(dsp_ptr, block_ptr)
          raise InvalidFormatError, "Vorbis block init failed (#{result})" unless result.zero?

          block_initialized = true

          all_samples = []
          ptr_size = FFI::Pointer.size

          audio_packets.each do |entry|
            pkt = Ogg::Packet.new(
              data: entry.fetch(:data),
              bos: entry.fetch(:bos, false),
              eos: entry.fetch(:eos, false),
              granulepos: entry[:granule_position].nil? ? -1 : entry[:granule_position],
              packetno: entry.fetch(:packetno, 0)
            )
            next unless Vorbis::Native.vorbis_synthesis(block_ptr, pkt.native).zero?

            Vorbis::Native.vorbis_synthesis_blockin(dsp_ptr, block_ptr)

            while (n = Vorbis::Native.vorbis_synthesis_pcmout(dsp_ptr, pcm_pp)).positive?
              ch_array_ptr = pcm_pp.read_pointer
              n.times do |i|
                channels.times do |ch|
                  ch_ptr = ch_array_ptr.get_pointer(ch * ptr_size)
                  all_samples << ch_ptr.get_float(i * 4)
                end
              end
              Vorbis::Native.vorbis_synthesis_read(dsp_ptr, n)
            end
          end

          if max_granule&.positive?
            target_sample_count = max_granule * channels
            all_samples = all_samples.first(target_sample_count) if all_samples.length > target_sample_count
          end

          result_buffer = Core::SampleBuffer.new(all_samples, format)

          if streaming && block
            each_sample_buffer_frame_slice(result_buffer, chunk_size, &block)
            nil
          elsif block
            yield result_buffer
            nil
          else
            result_buffer
          end
        ensure
          Vorbis::Native.vorbis_block_clear(block_ptr) if block_initialized
          Vorbis::Native.vorbis_dsp_clear(dsp_ptr) if dsp_initialized
          Vorbis::Native.vorbis_comment_clear(comment_ptr) if comment_ptr
          Vorbis::Native.vorbis_info_clear(info_ptr) if info_ptr
        end

        # ---------------------------------------------------------------------------
        # Metadata (using vorbis-ruby header parsing + ogg-ruby packet reading)
        # ---------------------------------------------------------------------------

        def parse_single_logical_stream_metadata(io)
          packet_entries, ogg_info = read_ogg_packets(io)
          raise InvalidFormatError, "missing Vorbis identification header" if packet_entries[0].nil?
          raise InvalidFormatError, "missing Vorbis comment header" if packet_entries[1].nil?
          raise InvalidFormatError, "missing Vorbis setup header" if packet_entries[2].nil?

          info_ptr = FFI::MemoryPointer.new(Vorbis::Native::VorbisInfo.size)
          comment_ptr = FFI::MemoryPointer.new(Vorbis::Native::VorbisComment.size)
          Vorbis::Native.vorbis_info_init(info_ptr)
          Vorbis::Native.vorbis_comment_init(comment_ptr)

          setup_parsed = false
          saved_channels = nil
          saved_rate = nil
          saved_bitrate_nominal = nil
          saved_bitrate_lower = nil
          saved_bitrate_upper = nil
          packet_entries.first(3).each_with_index do |entry, index|
            pkt = Ogg::Packet.new(
              data: entry.fetch(:data),
              bos: entry.fetch(:bos, index.zero?),
              eos: entry.fetch(:eos, false),
              packetno: entry.fetch(:packetno, index)
            )
            result = Vorbis::Native.vorbis_synthesis_headerin(info_ptr, comment_ptr, pkt.native)
            if result.zero? && index.zero?
              # Save info from identification header before setup header possibly clears VorbisInfo
              temp = Vorbis::Native::VorbisInfo.new(info_ptr)
              saved_channels = temp[:channels]
              saved_rate = temp[:rate]
              saved_bitrate_nominal = temp[:bitrate_nominal]
              saved_bitrate_lower = temp[:bitrate_lower]
              saved_bitrate_upper = temp[:bitrate_upper]
            end
            break unless result.zero?

            setup_parsed = (index == 2)
          end

          vinfo = Vorbis::Native::VorbisInfo.new(info_ptr)
          channels = saved_channels || vinfo[:channels]
          sample_rate = saved_rate || vinfo[:rate]
          nominal_bitrate_raw = saved_bitrate_nominal || vinfo[:bitrate_nominal]
          minimum_bitrate_raw = saved_bitrate_lower || vinfo[:bitrate_lower]
          maximum_bitrate_raw = saved_bitrate_upper || vinfo[:bitrate_upper]

          blocksize_small = nil
          blocksize_large = nil
          if setup_parsed
            bs = Vorbis::Native.vorbis_info_blocksize(info_ptr, 0)
            bl = Vorbis::Native.vorbis_info_blocksize(info_ptr, 1)
            blocksize_small = bs.positive? ? bs : nil
            blocksize_large = bl.positive? ? bl : nil
          end

          vc = Vorbis::Native::VorbisComment.new(comment_ptr)
          vendor = vc[:vendor].null? ? nil : vc[:vendor].read_string
          comments_hash = {}
          n_comments = vc[:comments]
          if n_comments.positive? && !vc[:user_comments].null?
            user_comments_ptr = vc[:user_comments]
            comment_lengths_ptr = vc[:comment_lengths]
            n_comments.times do |i|
              str_ptr = user_comments_ptr.get_pointer(i * FFI::Pointer.size)
              next if str_ptr.null?

              len = comment_lengths_ptr.get_int32(i * 4)
              next unless len.positive?

              str = str_ptr.read_bytes(len)
              key, value = str.split("=", 2)
              comments_hash[key.downcase] = value if key && value
            end
          end

          audio_packets = packet_entries.drop(3).select { |e| e.fetch(:kind) == :audio }
          non_audio_packets = packet_entries.drop(3).reject { |e| e.fetch(:kind) == :audio }
          known_granule_positions = audio_packets.filter_map { |e| e[:granule_position] }

          format = Core::Format.new(channels: channels, sample_rate: sample_rate, bit_depth: 32, sample_format: :float)
          sample_frame_count = ogg_info[:max_granule_position]
          duration = sample_frame_count ? Core::Duration.from_samples(sample_frame_count, format.sample_rate) : nil

          {
            format: format,
            sample_frame_count: sample_frame_count,
            duration: duration,
            vendor: vendor,
            comments: comments_hash,
            nominal_bitrate: nominal_bitrate_raw.positive? ? nominal_bitrate_raw : nil,
            minimum_bitrate: minimum_bitrate_raw.positive? ? minimum_bitrate_raw : nil,
            maximum_bitrate: maximum_bitrate_raw.positive? ? maximum_bitrate_raw : nil,
            blocksize_small: blocksize_small,
            blocksize_large: blocksize_large,
            ogg_serial_number: ogg_info[:serial_number],
            ogg_page_count: ogg_info[:page_count],
            ogg_packet_count: packet_entries.length,
            ogg_bos_page_count: ogg_info[:bos_page_count],
            ogg_eos_page_count: ogg_info[:eos_page_count],
            ogg_continued_page_count: ogg_info[:continued_page_count],
            vorbis_audio_packet_count: audio_packets.length,
            vorbis_non_audio_packet_count: non_audio_packets.length,
            vorbis_audio_packets_with_granule_count: known_granule_positions.length,
            first_audio_packet_granule_position: audio_packets.find { |e| !e[:granule_position].nil? }&.fetch(:granule_position),
            last_audio_packet_granule_position: audio_packets.reverse_each.find do |e|
              !e[:granule_position].nil?
            end&.fetch(:granule_position),
            vorbis_setup_parsed: setup_parsed,
            vorbis_codebook_count: nil,
            vorbis_codebook_dimensions: nil,
            vorbis_codebook_entries: nil,
            vorbis_codebook_lookup_types: nil,
            vorbis_codebook_used_entry_counts: nil,
            vorbis_codebook_sparse_count: nil,
            vorbis_codebook_huffman_complete_count: nil,
            vorbis_codebook_huffman_incomplete_count: nil,
            vorbis_codebook_huffman_max_codeword_length: nil,
            vorbis_floor_count: nil,
            vorbis_residue_count: nil,
            vorbis_floor_types: nil,
            vorbis_residue_types: nil,
            vorbis_mapping_count: nil,
            vorbis_mode_count: nil,
            vorbis_mode_bits: nil,
            vorbis_mode_blockflags: nil,
            vorbis_mode_mappings: nil,
            vorbis_mapping_submap_counts: nil,
            vorbis_mapping_coupling_step_counts: nil,
            vorbis_mapping_coupling_pairs: nil,
            vorbis_mapping_channel_muxes: nil,
            vorbis_mapping_submap_floors: nil,
            vorbis_mapping_submap_residues: nil,
            vorbis_mode_blocksizes: nil,
            vorbis_audio_packet_header_parsed_count: 0,
            vorbis_audio_packet_mode_histogram: {},
            vorbis_audio_packet_blocksize_histogram: {},
            vorbis_window_transition_histogram: {},
            vorbis_decode_plan_built: false,
            vorbis_decode_plan_packet_count: nil,
            vorbis_decode_plan_nominal_overlap_frame_total: nil,
            vorbis_decode_plan_known_granule_delta_count: nil,
            vorbis_decode_plan_nominal_minus_final_granule: nil,
            vorbis_output_assembly_preflight_ok: nil,
            vorbis_output_assembly_preflight_error: nil,
            vorbis_output_assembly_emitted_frame_count: nil,
            vorbis_output_assembly_trim_frames: nil,
            vorbis_output_assembly_window_curve_preflight_count: nil,
            vorbis_long_window_packet_count: nil,
            vorbis_short_window_packet_count: nil,
            setup_header_size: packet_entries[2]&.fetch(:data)&.bytesize
          }
        ensure
          Vorbis::Native.vorbis_comment_clear(comment_ptr) if comment_ptr
          Vorbis::Native.vorbis_info_clear(info_ptr) if info_ptr
        end

        # ---------------------------------------------------------------------------
        # Chained / interleaved stream merging (metadata)
        # ---------------------------------------------------------------------------

        def merge_chained_vorbis_metadata(chain_metadatas, chained_streams)
          metadatas = Array(chain_metadatas)
          streams = Array(chained_streams)
          raise InvalidFormatError, "OGG Vorbis chained metadata requires at least one logical stream" if metadatas.empty?
          raise InvalidFormatError, "OGG Vorbis chained metadata stream count mismatch" unless metadatas.length == streams.length

          first = metadatas.first.dup
          first_format = first.fetch(:format)
          logical_stream_formats = metadatas.map { |metadata| metadata.fetch(:format) }
          mixed_format_chain = logical_stream_formats.any? { |format| format != first_format }
          resampled_output_frame_counts = metadatas.map do |metadata|
            resampled_vorbis_sample_frame_count(
              metadata[:sample_frame_count].to_i,
              source_sample_rate: metadata.fetch(:format).sample_rate,
              target_sample_rate: first_format.sample_rate
            )
          end
          sample_frame_count = resampled_output_frame_counts.sum
          duration = Core::Duration.from_samples(sample_frame_count, first_format.sample_rate)

          sum_keys = %i[
            ogg_page_count
            ogg_packet_count
            ogg_bos_page_count
            ogg_eos_page_count
            ogg_continued_page_count
            vorbis_audio_packet_count
            vorbis_non_audio_packet_count
            vorbis_audio_packets_with_granule_count
            vorbis_audio_packet_header_parsed_count
          ]

          sum_keys.each do |key|
            values = metadatas.map { |metadata| metadata[key] }
            next if values.any?(&:nil?)

            first[key] = values.sum
          end

          first[:format] = first_format
          first[:sample_frame_count] = sample_frame_count
          first[:duration] = duration
          first[:ogg_serial_number] = streams.first.fetch(:serial_number)
          first[:ogg_serial_numbers] = streams.map { |stream| stream.fetch(:serial_number) }
          first[:ogg_logical_stream_count] = streams.length
          first[:ogg_logical_stream_formats] = logical_stream_formats
          first[:ogg_logical_stream_sample_frame_counts] = metadatas.map { |metadata| metadata[:sample_frame_count] }
          first[:ogg_logical_stream_output_frame_counts] = resampled_output_frame_counts
          first[:ogg_logical_stream_durations] = metadatas.map { |metadata| metadata[:duration] }
          first[:vorbis_chained] = true
          first[:vorbis_chained_mixed_format] = mixed_format_chain
          first[:vorbis_chained_resampled_sample_rate] = logical_stream_formats.any? do |format|
            format.sample_rate != first_format.sample_rate
          end

          first
        end

        def merge_interleaved_vorbis_metadata(chain_metadatas, chained_streams, physical_ogg_info)
          metadatas = Array(chain_metadatas)
          streams = Array(chained_streams)
          raise InvalidFormatError, "OGG Vorbis interleaved metadata requires at least one logical stream" if metadatas.empty?
          raise InvalidFormatError, "OGG Vorbis interleaved metadata stream count mismatch" unless metadatas.length == streams.length

          first = metadatas.first.dup
          first_format = first.fetch(:format)
          logical_stream_formats = metadatas.map { |metadata| metadata.fetch(:format) }
          resampled_output_frame_counts = metadatas.map do |metadata|
            resampled_vorbis_sample_frame_count(
              metadata[:sample_frame_count].to_i,
              source_sample_rate: metadata.fetch(:format).sample_rate,
              target_sample_rate: first_format.sample_rate
            )
          end
          sample_frame_count = resampled_output_frame_counts.max || 0
          duration = Core::Duration.from_samples(sample_frame_count, first_format.sample_rate)

          sum_keys = %i[
            ogg_page_count
            ogg_packet_count
            ogg_bos_page_count
            ogg_eos_page_count
            ogg_continued_page_count
            vorbis_audio_packet_count
            vorbis_non_audio_packet_count
            vorbis_audio_packets_with_granule_count
            vorbis_audio_packet_header_parsed_count
          ]

          sum_keys.each do |key|
            values = metadatas.map { |metadata| metadata[key] }
            next if values.any?(&:nil?)

            first[key] = values.sum
          end

          first[:format] = first_format
          first[:sample_frame_count] = sample_frame_count
          first[:duration] = duration
          first[:ogg_serial_number] = streams.first.fetch(:serial_number)
          first[:ogg_serial_numbers] = streams.map { |stream| stream.fetch(:serial_number) }
          first[:ogg_logical_stream_count] = streams.length
          first[:ogg_logical_stream_formats] = logical_stream_formats
          first[:ogg_logical_stream_sample_frame_counts] = metadatas.map { |metadata| metadata[:sample_frame_count] }
          first[:ogg_logical_stream_output_frame_counts] = resampled_output_frame_counts
          first[:ogg_logical_stream_durations] = metadatas.map { |metadata| metadata[:duration] }
          first[:vorbis_chained] = false
          first[:vorbis_interleaved_multistream] = true
          first[:vorbis_interleaved_multistream_mixed] = true
          first[:vorbis_interleaved_multistream_resampled_sample_rate] =
            logical_stream_formats.any? { |format| format.sample_rate != first_format.sample_rate }
          first[:vorbis_chained_mixed_format] = logical_stream_formats.any? { |format| format != first_format }
          first[:ogg_interleaved_multistream] = physical_ogg_info[:interleaved_multistream]
          first[:ogg_overlapping_logical_stream_serial_pairs] = physical_ogg_info[:overlapping_logical_stream_serial_pairs]

          first
        end

        # ---------------------------------------------------------------------------
        # Chained / interleaved stream decoding (high-level helpers)
        # ---------------------------------------------------------------------------

        def decode_chained_vorbis_read_if_needed(io_or_path, decode_mode:, target_format: nil)
          chained_streams, physical_ogg_info = read_ogg_logical_stream_chains_from_input(io_or_path, with_info: true)
          return nil unless chained_streams.length > 1

          if physical_ogg_info[:interleaved_multistream]
            decoded_buffers = chained_streams.map do |stream|
              read(StringIO.new(stream.fetch(:bytes)), decode_mode: decode_mode)
            end

            return mix_vorbis_sample_buffers(decoded_buffers, target_format: target_format)
          end

          decoded_buffers = chained_streams.map do |stream|
            read(StringIO.new(stream.fetch(:bytes)), format: target_format, decode_mode: decode_mode)
          end

          concatenate_vorbis_sample_buffers(decoded_buffers, target_format: target_format)
        end

        def stream_chained_vorbis_if_needed(io_or_path, chunk_size:, decode_mode:, &block)
          chained_streams, physical_ogg_info = read_ogg_logical_stream_chains_from_input(io_or_path, with_info: true)
          return false unless chained_streams.length > 1

          if physical_ogg_info[:interleaved_multistream]
            stream_metadatas = chained_streams.map do |stream|
              parse_single_logical_stream_metadata(StringIO.new(stream.fetch(:bytes)))
            end
            target_format = stream_metadatas.first.fetch(:format)
            return stream_interleaved_vorbis_logical_streams_mixed!(
              chained_streams,
              chunk_size: chunk_size,
              decode_mode: decode_mode,
              target_format: target_format,
              stream_metadatas: stream_metadatas, &block
            )
          end

          stream_metadatas = chained_streams.map do |stream|
            parse_single_logical_stream_metadata(StringIO.new(stream.fetch(:bytes)))
          end
          target_format = stream_metadatas.first.fetch(:format)
          same_sample_rate = stream_metadatas.all? { |metadata| metadata.fetch(:format).sample_rate == target_format.sample_rate }

          unless same_sample_rate
            chained_streams.each do |stream|
              normalized = normalize_vorbis_logical_stream_buffer_for_target(
                read(StringIO.new(stream.fetch(:bytes)), decode_mode: decode_mode),
                target_format
              )
              each_sample_buffer_frame_slice(normalized, chunk_size, &block)
            end
            return true
          end

          chained_format = nil
          chained_streams.each do |stream|
            stream_read(StringIO.new(stream.fetch(:bytes)), chunk_size: chunk_size, decode_mode: decode_mode) do |chunk|
              chained_format ||= chunk.format
              yield(chunk.format == chained_format ? chunk : chunk.convert(chained_format))
            end
          end

          true
        end

        def concatenate_vorbis_sample_buffers(buffers, target_format: nil)
          buffers = Array(buffers)
          raise InvalidFormatError, "OGG Vorbis chained decode did not produce any logical streams" if buffers.empty?

          first = buffers.first
          raise InvalidFormatError, "OGG Vorbis chained decode expected SampleBuffer outputs" unless first.is_a?(Core::SampleBuffer)
          raise InvalidParameterError, "target_format must be Core::Format" if !target_format.nil? && !target_format.is_a?(Core::Format)

          resolved_target_format = target_format || first.format
          combined = first.format == resolved_target_format ? first : first.convert(resolved_target_format)

          buffers.drop(1).reduce(combined) do |combined_buffer, buffer|
            raise InvalidFormatError, "OGG Vorbis chained decode expected SampleBuffer outputs" unless buffer.is_a?(Core::SampleBuffer)

            converted = normalize_vorbis_logical_stream_buffer_for_target(buffer, resolved_target_format)
            combined_buffer.concat(converted)
          end
        end

        def mix_vorbis_sample_buffers(buffers, target_format: nil)
          buffers = Array(buffers)
          raise InvalidFormatError, "OGG Vorbis multi-stream decode did not produce any logical streams" if buffers.empty?

          first = buffers.first
          raise InvalidFormatError, "OGG Vorbis multi-stream decode expected SampleBuffer outputs" unless first.is_a?(Core::SampleBuffer)
          raise InvalidParameterError, "target_format must be Core::Format" if !target_format.nil? && !target_format.is_a?(Core::Format)

          resolved_target_format = target_format || first.format

          work_format = resolved_target_format.with(sample_format: :float, bit_depth: 32)
          converted = buffers.map do |buffer|
            normalize_vorbis_logical_stream_buffer_for_target(buffer, work_format)
          end
          max_frames = converted.map(&:sample_frame_count).max || 0
          mixed_samples = Array.new(max_frames * work_format.channels, 0.0)

          converted.each do |buffer|
            buffer.samples.each_with_index do |sample, index|
              mixed_samples[index] += sample.to_f
            end
          end
          mixed_samples.map! { |sample| [[sample, -1.0].max, 1.0].min }

          mixed = Core::SampleBuffer.new(mixed_samples, work_format)
          return mixed if mixed.format == resolved_target_format

          mixed.convert(resolved_target_format)
        end

        def normalize_vorbis_logical_stream_buffer_for_target(buffer, target_format)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)
          raise InvalidParameterError, "target_format must be Core::Format" unless target_format.is_a?(Core::Format)

          normalized = if buffer.format.sample_rate == target_format.sample_rate
                         buffer
                       else
                         resample_vorbis_sample_buffer(buffer, target_sample_rate: target_format.sample_rate)
                       end
          normalized.format == target_format ? normalized : normalized.convert(target_format)
        end

        def resampled_vorbis_sample_frame_count(frame_count, source_sample_rate:, target_sample_rate:)
          frame_count = Integer(frame_count)
          source_sample_rate = Integer(source_sample_rate)
          target_sample_rate = Integer(target_sample_rate)
          raise InvalidParameterError, "frame_count must be non-negative" if frame_count.negative?
          raise InvalidParameterError, "source_sample_rate must be positive" unless source_sample_rate.positive?
          raise InvalidParameterError, "target_sample_rate must be positive" unless target_sample_rate.positive?

          return frame_count if source_sample_rate == target_sample_rate
          return 0 if frame_count.zero?

          ((frame_count * target_sample_rate.to_f) / source_sample_rate).round
        end

        def resample_vorbis_sample_buffer(buffer, target_sample_rate:)
          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)

          source_format = buffer.format
          source_sample_rate = source_format.sample_rate
          target_sample_rate = Integer(target_sample_rate)
          return buffer if source_sample_rate == target_sample_rate

          work_format = source_format.with(sample_format: :float, bit_depth: 32)
          work_buffer = (buffer.format == work_format ? buffer : buffer.convert(work_format))
          channels = work_format.channels
          source_frames = work_buffer.sample_frame_count
          target_frames = resampled_vorbis_sample_frame_count(
            source_frames,
            source_sample_rate: source_sample_rate,
            target_sample_rate: target_sample_rate
          )
          return Core::SampleBuffer.new([], work_format.with(sample_rate: target_sample_rate)) if target_frames.zero?

          channel_samples = Array.new(channels) { [] }
          work_buffer.samples.each_slice(channels) do |frame|
            channels.times { |channel_index| channel_samples[channel_index] << frame.fetch(channel_index).to_f }
          end

          resampled_channels = channel_samples.map do |samples|
            if samples.empty?
              Array.new(target_frames, 0.0)
            elsif samples.length == 1
              Array.new(target_frames, samples.first.to_f)
            else
              Array.new(target_frames) do |target_index|
                source_position = (target_index * source_sample_rate.to_f) / target_sample_rate
                left_index = source_position.floor
                left_index = 0 if left_index.negative?
                if left_index >= (samples.length - 1)
                  samples.last.to_f
                else
                  right_index = left_index + 1
                  frac = source_position - left_index
                  left = samples.fetch(left_index).to_f
                  right = samples.fetch(right_index).to_f
                  left + ((right - left) * frac)
                end
              end
            end
          end

          interleaved = []
          target_frames.times do |frame_index|
            channels.times do |channel_index|
              interleaved << resampled_channels.fetch(channel_index).fetch(frame_index)
            end
          end

          Core::SampleBuffer.new(interleaved, work_format.with(sample_rate: target_sample_rate))
        end

        def stream_interleaved_vorbis_logical_streams_mixed!(
          chained_streams,
          chunk_size:,
          decode_mode:,
          target_format: nil,
          stream_metadatas: nil, &block
        )
          unless block_given?
            return enum_for(
              __method__,
              chained_streams,
              chunk_size: chunk_size,
              decode_mode: decode_mode,
              target_format: target_format,
              stream_metadatas: stream_metadatas
            )
          end

          streams = Array(chained_streams)
          raise InvalidFormatError, "OGG Vorbis interleaved stream decode requires logical streams" if streams.empty?

          metadatas = stream_metadatas ? Array(stream_metadatas) : nil
          if metadatas && metadatas.length != streams.length
            raise InvalidFormatError, "OGG Vorbis interleaved stream metadata count mismatch"
          end

          if metadatas
            resolved_target_format = target_format || metadatas.first.fetch(:format)
            same_sample_rate = metadatas.all? do |metadata|
              metadata.fetch(:format).sample_rate == resolved_target_format.sample_rate
            end
            unless same_sample_rate
              return stream_interleaved_vorbis_logical_streams_mixed_resampled!(
                streams,
                stream_metadatas: metadatas,
                target_format: resolved_target_format,
                chunk_size: chunk_size,
                decode_mode: decode_mode, &block
              )
            end
          end

          enumerators = streams.map do |stream|
            stream_read(
              StringIO.new(stream.fetch(:bytes)),
              chunk_size: chunk_size,
              decode_mode: decode_mode
            )
          end
          loop do
            chunks = enumerators.map do |enumerator|
              enumerator.next
            rescue StopIteration
              nil
            end
            active_chunks = chunks.compact
            break if active_chunks.empty?

            yield mix_vorbis_sample_buffers(active_chunks)
          end

          true
        end

        def stream_interleaved_vorbis_logical_streams_mixed_resampled!(
          chained_streams,
          stream_metadatas:,
          target_format:,
          chunk_size:,
          decode_mode:
        )
          unless block_given?
            return enum_for(
              __method__,
              chained_streams,
              stream_metadatas: stream_metadatas,
              target_format: target_format,
              chunk_size: chunk_size,
              decode_mode: decode_mode
            )
          end

          streams = Array(chained_streams)
          metadatas = Array(stream_metadatas)
          raise InvalidFormatError, "OGG Vorbis interleaved stream metadata count mismatch" unless streams.length == metadatas.length
          raise InvalidFormatError, "OGG Vorbis interleaved stream decode requires logical streams" if streams.empty?

          target_work_format = target_format.with(sample_format: :float, bit_depth: 32)
          stream_states = streams.zip(metadatas).map do |stream, _metadata|
            {
              enumerator: stream_read(
                StringIO.new(stream.fetch(:bytes)),
                chunk_size: chunk_size,
                decode_mode: decode_mode
              ),
              source_eof: false,
              pending_samples: [],
              target_work_format: target_work_format,
              resampler_initialized: false,
              resampler: nil
            }
          end

          loop do
            made_progress = false
            stream_states.each do |stream_state|
              progress = ensure_vorbis_interleaved_stream_pending_frames!(
                stream_state,
                min_frames: chunk_size
              )
              made_progress ||= progress
            end

            pending_frame_counts = stream_states.map do |stream_state|
              stream_state.fetch(:pending_samples).length / target_work_format.channels
            end
            if pending_frame_counts.any? { |count| count >= chunk_size }
              emit_frames = chunk_size
            elsif stream_states.all? { |stream_state| vorbis_interleaved_stream_state_source_drained?(stream_state) }
              emit_frames = pending_frame_counts.max || 0
              break if emit_frames.zero?
            else
              raise InvalidFormatError, "interleaved Vorbis streaming resampler made no progress" unless made_progress

              next
            end

            mixed_inputs = stream_states.map do |stream_state|
              take_vorbis_interleaved_stream_pending_chunk!(stream_state, frame_count: emit_frames)
            end.compact
            yield mix_vorbis_sample_buffers(mixed_inputs, target_format: target_work_format)
          end

          true
        end

        def ensure_vorbis_interleaved_stream_pending_frames!(stream_state, min_frames:)
          progress = false
          target_work_format = stream_state.fetch(:target_work_format)
          pending_samples = stream_state.fetch(:pending_samples)
          pending_frame_count = pending_samples.length / target_work_format.channels

          while pending_frame_count < min_frames
            if (resampler = stream_state[:resampler])
              drained = drain_vorbis_streaming_linear_resampler_chunk!(
                resampler,
                max_frames: (min_frames - pending_frame_count)
              )
              if drained
                normalized = drained.format == target_work_format ? drained : drained.convert(target_work_format)
                pending_samples.concat(normalized.samples)
                pending_frame_count = pending_samples.length / target_work_format.channels
                progress = true
                next
              end
            end

            break if stream_state[:source_eof]

            begin
              chunk = stream_state.fetch(:enumerator).next
              append_vorbis_interleaved_stream_pending_output_chunk!(stream_state, chunk)
              pending_frame_count = pending_samples.length / target_work_format.channels
              progress = true
            rescue StopIteration
              stream_state[:source_eof] = true
              finish_vorbis_streaming_linear_resampler!(resampler) if resampler
              progress = true
            end
          end

          progress
        end

        def append_vorbis_interleaved_stream_pending_output_chunk!(stream_state, chunk)
          raise InvalidParameterError, "chunk must be Core::SampleBuffer" unless chunk.is_a?(Core::SampleBuffer)

          target_work_format = stream_state.fetch(:target_work_format)
          pending_samples = stream_state.fetch(:pending_samples)

          unless stream_state[:resampler_initialized]
            stream_state[:resampler] = build_vorbis_streaming_linear_resampler_state(
              source_format: chunk.format,
              target_sample_rate: target_work_format.sample_rate
            )
            stream_state[:resampler_initialized] = true
          end

          if (resampler = stream_state[:resampler])
            feed_vorbis_streaming_linear_resampler_chunk!(resampler, chunk)
            while (drained = drain_vorbis_streaming_linear_resampler_chunk!(resampler, max_frames: nil))
              normalized = drained.format == target_work_format ? drained : drained.convert(target_work_format)
              pending_samples.concat(normalized.samples)
            end
            return nil
          end

          normalized = if chunk.format == target_work_format
                         chunk
                       else
                         normalize_vorbis_logical_stream_buffer_for_target(chunk,
                                                                           target_work_format)
                       end
          pending_samples.concat(normalized.samples)
          nil
        end

        def take_vorbis_interleaved_stream_pending_chunk!(stream_state, frame_count:)
          frame_count = Integer(frame_count)
          raise InvalidParameterError, "frame_count must be non-negative" if frame_count.negative?

          pending_samples = stream_state.fetch(:pending_samples)
          target_work_format = stream_state.fetch(:target_work_format)
          channels = target_work_format.channels
          available_frames = pending_samples.length / channels
          take_frames = [frame_count, available_frames].min
          return nil if take_frames.zero?

          samples = pending_samples.slice!(0, take_frames * channels)
          Core::SampleBuffer.new(samples, target_work_format)
        end

        def vorbis_interleaved_stream_state_source_drained?(stream_state)
          return false unless stream_state[:source_eof]

          resampler = stream_state[:resampler]
          resampler.nil? || vorbis_streaming_linear_resampler_finished?(resampler)
        end

        def build_vorbis_streaming_linear_resampler_state(source_format:, target_sample_rate:)
          raise InvalidParameterError, "source_format must be Core::Format" unless source_format.is_a?(Core::Format)

          target_sample_rate = Integer(target_sample_rate)
          return nil if source_format.sample_rate == target_sample_rate

          source_work_format = source_format.with(sample_format: :float, bit_depth: 32)
          {
            source_work_format: source_work_format,
            target_work_format: source_work_format.with(sample_rate: target_sample_rate),
            source_sample_rate: source_work_format.sample_rate,
            target_sample_rate: target_sample_rate,
            channels: source_work_format.channels,
            source_buffer_samples: [],
            source_buffer_start_frame: 0,
            total_source_frames: 0,
            next_target_frame_index: 0,
            source_eof: false,
            final_target_frame_count: nil
          }
        end

        def feed_vorbis_streaming_linear_resampler_chunk!(state, chunk)
          raise InvalidParameterError, "state must be a resampler state Hash" unless state.is_a?(Hash)
          raise InvalidParameterError, "chunk must be Core::SampleBuffer" unless chunk.is_a?(Core::SampleBuffer)

          source_work_format = state.fetch(:source_work_format)
          if chunk.format.sample_rate != source_work_format.sample_rate
            raise InvalidFormatError,
                  "streaming resampler source sample rate mismatch " \
                  "(expected #{source_work_format.sample_rate}, got #{chunk.format.sample_rate})"
          end

          normalized = chunk.format == source_work_format ? chunk : chunk.convert(source_work_format)
          state.fetch(:source_buffer_samples).concat(normalized.samples.map(&:to_f))
          state[:total_source_frames] += normalized.sample_frame_count
          nil
        end

        def finish_vorbis_streaming_linear_resampler!(state)
          raise InvalidParameterError, "state must be a resampler state Hash" unless state.is_a?(Hash)
          return nil if state[:source_eof]

          state[:source_eof] = true
          state[:final_target_frame_count] = resampled_vorbis_sample_frame_count(
            state.fetch(:total_source_frames),
            source_sample_rate: state.fetch(:source_sample_rate),
            target_sample_rate: state.fetch(:target_sample_rate)
          )
          nil
        end

        def vorbis_streaming_linear_resampler_finished?(state)
          return false unless state.is_a?(Hash)
          return false unless state[:source_eof]
          return false if state[:final_target_frame_count].nil?

          state.fetch(:next_target_frame_index) >= state.fetch(:final_target_frame_count)
        end

        def drain_vorbis_streaming_linear_resampler_chunk!(state, max_frames:)
          raise InvalidParameterError, "state must be a resampler state Hash" unless state.is_a?(Hash)

          channels = state.fetch(:channels)
          source_sample_rate = state.fetch(:source_sample_rate)
          target_sample_rate = state.fetch(:target_sample_rate)
          total_source_frames = state.fetch(:total_source_frames)
          if total_source_frames.zero?
            return nil unless state[:source_eof]
            return nil if state.fetch(:final_target_frame_count).to_i.zero?
          end

          if max_frames.nil?
            limit = Float::INFINITY
          else
            max_frames = Integer(max_frames)
            raise InvalidParameterError, "max_frames must be non-negative" if max_frames.negative?
            return nil if max_frames.zero?

            limit = max_frames
          end

          final_target_frame_count = state[:final_target_frame_count]
          output_samples = []
          produced_frames = 0

          while produced_frames < limit
            next_target_frame_index = state.fetch(:next_target_frame_index)
            break if !final_target_frame_count.nil? && next_target_frame_index >= final_target_frame_count
            break if total_source_frames.zero?

            source_position = (next_target_frame_index * source_sample_rate.to_f) / target_sample_rate
            left_index = source_position.floor
            left_index = 0 if left_index.negative?
            break if !state[:source_eof] && (left_index + 1) >= total_source_frames

            if left_index >= (total_source_frames - 1)
              left_index = total_source_frames - 1
              right_index = left_index
              frac = 0.0
            else
              right_index = left_index + 1
              frac = source_position - left_index
            end

            channels.times do |channel_index|
              left = vorbis_streaming_linear_resampler_source_sample(state, left_index, channel_index)
              if right_index == left_index
                output_samples << left
              else
                right = vorbis_streaming_linear_resampler_source_sample(state, right_index, channel_index)
                output_samples << (left + ((right - left) * frac))
              end
            end

            state[:next_target_frame_index] = next_target_frame_index + 1
            produced_frames += 1
          end

          compact_vorbis_streaming_linear_resampler_source_buffer!(state)
          return nil if output_samples.empty?

          Core::SampleBuffer.new(output_samples, state.fetch(:target_work_format))
        end

        def vorbis_streaming_linear_resampler_source_sample(state, absolute_frame_index, channel_index)
          channels = state.fetch(:channels)
          start_frame = state.fetch(:source_buffer_start_frame)
          local_frame_index = absolute_frame_index - start_frame
          raise InvalidFormatError, "streaming resampler source buffer underflow" if local_frame_index.negative?

          sample_index = (local_frame_index * channels) + channel_index
          sample = state.fetch(:source_buffer_samples)[sample_index]
          raise InvalidFormatError, "streaming resampler source buffer overflow" if sample.nil?

          sample.to_f
        end

        def compact_vorbis_streaming_linear_resampler_source_buffer!(state)
          total_source_frames = state.fetch(:total_source_frames)
          return nil if total_source_frames.zero?

          next_needed_frame = if vorbis_streaming_linear_resampler_finished?(state)
                                total_source_frames
                              else
                                source_sample_rate = state.fetch(:source_sample_rate)
                                target_sample_rate = state.fetch(:target_sample_rate)
                                source_position = (state.fetch(:next_target_frame_index) * source_sample_rate.to_f) / target_sample_rate
                                [source_position.floor, 0].max
                              end
          next_needed_frame = if state[:source_eof]
                                [next_needed_frame, total_source_frames].min
                              else
                                [next_needed_frame, (total_source_frames - 1)].min
                              end

          keep_from_frame = [next_needed_frame, total_source_frames].min
          drop_frames = keep_from_frame - state.fetch(:source_buffer_start_frame)
          return nil unless drop_frames.positive?

          channels = state.fetch(:channels)
          state.fetch(:source_buffer_samples).slice!(0, drop_frames * channels)
          state[:source_buffer_start_frame] += drop_frames
          nil
        end

        def each_sample_buffer_frame_slice(buffer, chunk_size)
          return enum_for(__method__, buffer, chunk_size) unless block_given?

          raise InvalidParameterError, "buffer must be Core::SampleBuffer" unless buffer.is_a?(Core::SampleBuffer)
          raise InvalidParameterError, "chunk_size must be a positive Integer" unless chunk_size.is_a?(Integer) && chunk_size.positive?

          total_frames = buffer.sample_frame_count
          frame_offset = 0
          while frame_offset < total_frames
            frame_length = [chunk_size, total_frames - frame_offset].min
            yield buffer.slice(frame_offset, frame_length)
            frame_offset += frame_length
          end

          nil
        end

        # ---------------------------------------------------------------------------
        # Packet classification
        # ---------------------------------------------------------------------------

        def classify_vorbis_packet(packet)
          return :unknown if packet.nil? || packet.empty?

          first_byte = packet.getbyte(0)
          return :audio if first_byte.nobits?(0x01)

          return :identification_header if packet.bytesize >= 7 && first_byte == IDENTIFICATION_HEADER_TYPE && packet[1,
                                                                                                                      6] == VORBIS_SIGNATURE
          return :comment_header if packet.bytesize >= 7 && first_byte == COMMENT_HEADER_TYPE && packet[1, 6] == VORBIS_SIGNATURE
          return :setup_header if packet.bytesize >= 7 && first_byte == SETUP_HEADER_TYPE && packet[1, 6] == VORBIS_SIGNATURE

          :unknown
        end

        # ---------------------------------------------------------------------------
        # IO helpers
        # ---------------------------------------------------------------------------

        def open_input(io_or_path)
          return [io_or_path, false] if io_or_path.respond_to?(:read)
          raise InvalidParameterError, "input path must be String or IO: #{io_or_path.inspect}" unless io_or_path.is_a?(String)

          [File.open(io_or_path, "rb"), true]
        rescue Errno::ENOENT
          raise InvalidFormatError, "input file not found: #{io_or_path}"
        end

        def open_output(io_or_path)
          return [io_or_path, false] if io_or_path.respond_to?(:write)
          raise InvalidParameterError, "output path must be String or IO: #{io_or_path.inspect}" unless io_or_path.is_a?(String)

          [File.open(io_or_path, "wb"), true]
        end

        def ensure_seekable!(io)
          return if io.respond_to?(:seek) && io.respond_to?(:rewind)

          raise StreamError, "OGG Vorbis codec requires seekable IO"
        end
      end
    end
  end
end
