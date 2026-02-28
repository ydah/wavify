# frozen_string_literal: true

require_relative "wavify/version"
require_relative "wavify/errors"
require_relative "wavify/core/format"
require_relative "wavify/core/duration"
require_relative "wavify/core/sample_buffer"
require_relative "wavify/core/stream"
require_relative "wavify/codecs/base"
require_relative "wavify/codecs/raw"
require_relative "wavify/codecs/wav"
require_relative "wavify/codecs/flac"
require_relative "wavify/codecs/ogg_vorbis"
require_relative "wavify/codecs/aiff"
require_relative "wavify/codecs/registry"
require_relative "wavify/dsp/oscillator"
require_relative "wavify/dsp/envelope"
require_relative "wavify/dsp/filter"
require_relative "wavify/dsp/effects"
require_relative "wavify/sequencer"
require_relative "wavify/audio"
require_relative "wavify/dsl"

##
# Wavify is a pure Ruby audio processing toolkit with immutable transforms,
# multiple codecs, DSP primitives, and a small sequencing DSL.
module Wavify
end
