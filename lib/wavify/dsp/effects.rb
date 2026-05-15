# frozen_string_literal: true

require_relative "effects/effect_base"
require_relative "effects/delay"
require_relative "effects/reverb"
require_relative "effects/chorus"
require_relative "effects/distortion"
require_relative "effects/compressor"
require_relative "effects/limiter"
require_relative "effects/soft_limiter"
require_relative "effects/noise_gate"
require_relative "effects/tremolo"
require_relative "effects/bitcrusher"
require_relative "effects/expander"
require_relative "effects/auto_pan"
require_relative "effects/stereo_widener"
require_relative "effects/eq"

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
