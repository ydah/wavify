# frozen_string_literal: true

require_relative "effects/effect_base"
require_relative "effects/envelope_controlled_effect"
require_relative "effects/delay"
require_relative "effects/reverb"
require_relative "effects/chorus"
require_relative "effects/distortion"
require_relative "effects/compressor"
require_relative "effects/limiter"
require_relative "effects/soft_limiter"
require_relative "effects/noise_gate"
require_relative "effects/tremolo"
require_relative "effects/vibrato"
require_relative "effects/flanger"
require_relative "effects/phaser"
require_relative "effects/bitcrusher"
require_relative "effects/expander"
require_relative "effects/auto_pan"
require_relative "effects/stereo_widener"
require_relative "effects/eq"
require_relative "effects/effect_chain"
require_relative "effects/mastering_chain"
require_relative "effects/podcast_chain"

module Wavify
  module DSP
    # Built-in audio effects namespace.
    module Effects
      BUILTIN_EFFECTS = {
        delay: Delay,
        reverb: Reverb,
        chorus: Chorus,
        distortion: Distortion,
        compressor: Compressor,
        limiter: Limiter,
        soft_limiter: SoftLimiter,
        noise_gate: NoiseGate,
        tremolo: Tremolo,
        vibrato: Vibrato,
        flanger: Flanger,
        phaser: Phaser,
        bitcrusher: Bitcrusher,
        expander: Expander,
        auto_pan: AutoPan,
        stereo_widener: StereoWidener,
        eq: EQ,
        mastering_chain: MasteringChain,
        podcast_chain: PodcastChain
      }.freeze

      class << self
        # Registers an effect class or factory under a DSL-friendly name.
        #
        # @param name [Symbol, String]
        # @param factory [Class, #call]
        # @return [Class, #call]
        def register(name, factory = nil, &block)
          key = normalize_effect_name!(name)
          value = factory || block
          raise InvalidParameterError, "effect factory must be a Class or callable object" unless effect_factory?(value)

          registry_mutex.synchronize { registry[key] = value }
        end

        # Removes a custom effect or restores a built-in implementation.
        def unregister(name)
          key = normalize_effect_name!(name)
          registry_mutex.synchronize do
            previous = registry[key]
            if BUILTIN_EFFECTS.key?(key)
              registry[key] = BUILTIN_EFFECTS.fetch(key)
            else
              registry.delete(key)
            end
            previous
          end
        end

        # Builds a registered effect instance.
        #
        # @param name [Symbol, String]
        # @return [Object]
        def build(name, **params)
          key = normalize_effect_name!(name)
          factory = registry_mutex.synchronize { registry[key] }
          raise InvalidParameterError, "unsupported effect: #{key}" unless factory

          effect = factory.is_a?(Class) ? factory.new(**params) : factory.call(**params)
          return effect if effect.respond_to?(:process) || effect.respond_to?(:call) || effect.respond_to?(:apply)

          raise InvalidParameterError, "registered effect #{key} must build a processor"
        end

        # @return [Hash<Symbol, Object>]
        def registered_effects
          registry_mutex.synchronize { registry.dup.freeze }
        end

        private

        def registry
          @registry ||= BUILTIN_EFFECTS.dup
        end

        def registry_mutex
          @registry_mutex ||= Mutex.new
        end

        def normalize_effect_name!(name)
          raise InvalidParameterError, "effect name must be Symbol or String" unless name.is_a?(Symbol) || name.is_a?(String)

          name.to_sym
        end

        def effect_factory?(value)
          value.is_a?(Class) || value.respond_to?(:call)
        end
      end
    end
  end
end

module Wavify
  # Convenience alias for {Wavify::DSP::Effects}.
  Effects = DSP::Effects unless const_defined?(:Effects)
end
