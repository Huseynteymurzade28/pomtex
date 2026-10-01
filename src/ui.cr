require "colorize"

module Pomtex
  # Terminal output helpers shared by every command.
  module UI
    extend self

    class_property verbose : Bool = false
    class_property quiet : Bool = false

    def setup : Nil
      # Colour only on a TTY; the default behaviour since Crystal 1.17.
      {% if compare_versions(Crystal::VERSION, "1.17.0") < 0 %}
        Colorize.on_tty_only!
      {% end %}
    end

    def step(message : String) : Nil
      return if quiet
      STDERR.puts "#{"●".colorize(:red)} #{message}"
    end

    def ok(message : String) : Nil
      return if quiet
      STDERR.puts "  #{"✓".colorize(:green)} #{message}"
    end

    def info(message : String) : Nil
      return if quiet
      STDERR.puts "  #{message}"
    end

    def warn(message : String) : Nil
      STDERR.puts "#{"!".colorize(:yellow)} #{message}"
    end

    def error(message : String) : Nil
      STDERR.puts "#{"✗".colorize(:red).bold} #{message}"
    end

    def debug(message : String) : Nil
      STDERR.puts "  #{message.colorize(:dark_gray)}" if verbose
    end

    def bytes(size : Int) : String
      size.humanize_bytes(format: :JEDEC)
    end

    def duration(span : Time::Span) : String
      span.total_seconds >= 1 ? "#{span.total_seconds.round(1)}s" : "#{span.total_milliseconds.round.to_i}ms"
    end
  end

  class Error < Exception
  end

  # Monotonic clock: `Time.instant` on newer compilers, `Time.monotonic` on older ones.
  {% if Time.class.has_method?(:instant) %}
    alias Instant = Time::Instant

    def self.clock : Instant
      Time.instant
    end
  {% else %}
    alias Instant = Time::Span

    def self.clock : Instant
      Time.monotonic
    end
  {% end %}
end
