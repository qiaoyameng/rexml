# frozen_string_literal: false
require "bigdecimal"
require_relative "validationexception"

module REXML
  module Validation
    # Raised while turning a lexical string into a value space object.
    class DatatypeException < RuntimeError
    end

    # The RELAX NG datatyping protocol.  A datatype library is identified by
    # its namespace URI and provides named +Datatype+ implementations.
    # Libraries are selected through the +datatypeLibrary+ attribute of
    # +data+ elements and looked up in +DatatypeLibraryRegistry+.
    class DatatypeLibrary
      def initialize uri
        @uri = uri
        @datatypes = {}
      end

      attr_reader :uri

      def register name, datatype
        @datatypes[name] = datatype
        self
      end

      # Returns the named datatype or rejects the schema at preparation time.
      def datatype name
        @datatypes.fetch(name) do
          raise ValidationException.new(
            "RELAX NG datatype '#{name}' is not supported by "+
            "datatype library '#{@uri}'")
        end
      end
    end

    class DatatypeLibraryRegistry
      def initialize
        @libraries = {}
      end

      def register uri, library
        @libraries[uri] = library
      end

      # Selects a library by URI.  Unknown libraries are rejected while the
      # schema is prepared instead of being silently ignored.
      def library uri
        @libraries.fetch(uri) do
          raise ValidationException.new(
            "Unknown RELAX NG datatype library: #{uri.inspect}")
        end
      end

      def include? uri
        @libraries.key? uri
      end
    end

    # A single named type.  Subclasses implement #parse (lexical space ->
    # value space) and may restrict the set of applicable facets.
    class Datatype
      APPLICABLE_FACETS = %w[enumeration].freeze

      def initialize name, applicable_facets = self.class::APPLICABLE_FACETS
        @name = name
        @applicable_facets = applicable_facets
      end

      attr_reader :name

      # Builds a validator for the given facet name/value pairs.  Facets that
      # do not apply to the type are rejected while the schema is prepared.
      def validator params, except_patterns = []
        facets = {}
        params.each do |facet, literal|
          unless @applicable_facets.include? facet
            raise ValidationException.new(
              "Facet '#{facet}' is not applicable to datatype '#{@name}'")
          end
          (facets[facet] ||= []) << parse_facet(facet, literal)
        end
        DatatypeValidator.new(self, facets, except_patterns)
      end

      # Lexical space -> value space.  Raises DatatypeException for literals
      # outside the lexical space.
      def parse literal
        literal
      end

      # Comparison in the value space.
      def equal? value, other
        value == other
      end

      def inspect
        "#<#{self.class.name} #{@name}>"
      end

      protected

      def parse_facet facet, literal
        return parse(literal) if facet == "enumeration"
        raise ValidationException.new(
          "Unsupported facet '#{facet}' for datatype '#{@name}'")
      end
    end

    # A type bound to concrete facets.  The lexical space of the facets is
    # checked first; the data element's except patterns only exclude a value
    # after the main type (including facets) validates successfully.
    class DatatypeValidator
      def initialize datatype, facets, except_patterns
        @datatype = datatype
        @facets = facets
        @except_patterns = except_patterns
      end

      attr_reader :datatype

      def valid? literal
        value = @datatype.parse(literal)
        @facets.each do |facet, facet_values|
          case facet
          when "enumeration"
            return false unless
              facet_values.any? { |v| @datatype.equal?(value, v) }
          when "length"
            return false unless facet_values.first == value.length
          when "minInclusive"
            return false unless (value <=> facet_values.first) >= 0
          when "maxInclusive"
            return false unless (value <=> facet_values.first) <= 0
          end
        end
        return false if
          @except_patterns.any? { |pattern| pattern.excludes?(@datatype, value, literal) }
        true
      rescue DatatypeException
        false
      end

      def inspect
        "#<DatatypeValidator #{@datatype.name} #{@facets.inspect}"+
          "#{@except_patterns.empty? ? '' : ' except=' + @except_patterns.inspect}>"
      end
    end

    # <except><value>...</value></except> and
    # <except><data .../></except> patterns.
    class ExceptValue
      def initialize value_literal, datatype
        @value_literal = value_literal
        @datatype = datatype
        @value = datatype.parse(value_literal)
      end

      attr_reader :value_literal

      def excludes? datatype, value, _literal
        datatype.equal?(value, @value)
      end
    end

    class ExceptData
      def initialize validator
        @validator = validator
      end

      def excludes? _datatype, _value, literal
        @validator.valid?(literal)
      end
    end

    # XML Schema string: any literal is valid.
    class StringDatatype < Datatype
      APPLICABLE_FACETS = %w[length enumeration].freeze

      protected

      def parse_facet facet, literal
        return literal if facet == "length" || facet == "enumeration"
        super
      end
    end

    # XML Schema token: the value space collapses XML whitespace and trims
    # leading/trailing whitespace.
    class TokenDatatype < StringDatatype
      def parse literal
        literal.gsub(/[\x20\t\r\n]+/, " ").strip
      end
    end

    # XML Schema boolean: true, false, 1 and 0 only.
    class BooleanDatatype < Datatype
      APPLICABLE_FACETS = %w[pattern enumeration].freeze

      LITERALS = {
        "true" => true, "false" => false, "1" => true, "0" => false
      }.freeze

      def parse literal
        unless LITERALS.key? literal
          raise DatatypeException.new(
            "'#{literal}' is not a valid boolean literal")
        end
        LITERALS[literal]
      end
    end

    class OrderedDatatype < Datatype
      def parse_facet facet, literal
        return parse(literal) if facet == "minInclusive" || facet == "maxInclusive"
        super
      end
    end

    # XML Schema integer: an optional sign followed by digits.  Stored as
    # Integer so comparisons are exact.
    class IntegerDatatype < OrderedDatatype
      APPLICABLE_FACETS =
        %w[minInclusive maxInclusive enumeration].freeze
      LEXICAL = /\A[+-]?\d+\z/.freeze

      def parse literal
        unless LEXICAL.match? literal
          raise DatatypeException.new(
            "'#{literal}' is not a valid integer literal")
        end
        Integer(literal, 10)
      end
    end

    # XML Schema decimal: an optional sign, digits and at most one decimal
    # point.  BigDecimal is used so comparisons happen in the exact value
    # space instead of using floating point.
    class DecimalDatatype < OrderedDatatype
      APPLICABLE_FACETS =
        %w[minInclusive maxInclusive enumeration].freeze
      LEXICAL = /\A[+-]?(\d+\.?\d*|\.\d+)\z/.freeze

      def parse literal
        unless LEXICAL.match? literal
          raise DatatypeException.new(
            "'#{literal}' is not a valid decimal literal")
        end
        BigDecimal(literal)
      end

      def equal? value, other
        other.is_a?(BigDecimal) && value == other
      end
    end

    # The built-in RELAX NG library offers string and token only.
    BUILTIN_LIBRARY_URI = nil

    def self.builtin_library
      DatatypeLibrary.new(BUILTIN_LIBRARY_URI).
        register("string", StringDatatype.new("string")).
        register("token", TokenDatatype.new("token"))
    end

    XML_SCHEMA_LIBRARY_URI = "http://www.w3.org/2001/XMLSchema-datatypes"

    def self.xml_schema_library
      DatatypeLibrary.new(XML_SCHEMA_LIBRARY_URI).
        register("string", StringDatatype.new("string")).
        register("token", TokenDatatype.new("token")).
        register("boolean", BooleanDatatype.new("boolean")).
        register("integer", IntegerDatatype.new("integer")).
        register("decimal", DecimalDatatype.new("decimal"))
    end

    DEFAULT_REGISTRY = DatatypeLibraryRegistry.new
    DEFAULT_REGISTRY.register(
      "http://www.w3.org/2001/XMLSchema-datatypes", xml_schema_library)
    DEFAULT_REGISTRY.register(
      "http://www.w3.org/2001/XMLSchema", xml_schema_library)
  end
end
