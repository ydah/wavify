# frozen_string_literal: true

require_relative "effects/effect_base"
require_relative "effects/delay"
require_relative "effects/reverb"
require_relative "effects/chorus"
require_relative "effects/distortion"
require_relative "effects/compressor"

module Wavify
  module DSP
    # Built-in audio effects namespace.
    module Effects
    end
  end
end

module Wavify
  # Convenience alias for {Wavify::DSP::Effects}.
  Effects = DSP::Effects unless const_defined?(:Effects)
end
