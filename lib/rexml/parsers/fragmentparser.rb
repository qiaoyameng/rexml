# frozen_string_literal: false
require_relative '../parseexception'
require_relative '../undefinednamespaceexception'
require_relative '../element'
require_relative '../attribute'
require_relative '../text'
require_relative '../comment'
require_relative '../cdata'
require_relative '../instruction'
require_relative 'baseparser'

module REXML
  module Parsers
    # Parses a stand-alone XML fragment in the namespace context of a
    # given element.
    #
    # Unlike a complete document, a fragment may contain several sibling
    # nodes (elements, text, comments, CDATA sections and processing
    # instructions), may not contain an XML declaration or a DOCTYPE, and
    # cannot close tags inherited from the context.
    #
    # The context element is never modified: it is used only to resolve the
    # in-scope namespace bindings.
    class FragmentParser
      # Creates a new fragment parser.
      #
      # +source+:: the XML fragment (a String or an IO-like object).
      # +context+:: the REXML::Element whose in-scope namespaces are visible
      #             to the fragment.
      def initialize( source, context )
        unless context.is_a?(Element)
          raise ArgumentError,
                "context must be an REXML::Element but was #{context.class}"
        end
        @parser = BaseParser.new(source,
                                fragment: true,
                                initial_namespaces: context.namespaces)
        @holder = Element.new("")
        @holder.context = context.context
        seed_holder_namespaces(context)
      end

      def add_listener( listener )
        @parser.add_listener( listener )
      end

      # Parses the fragment and returns an array of independent nodes.
      def parse
        build_context = @holder
        begin
          until (event = @parser.pull)[0] == :end_document
            case event[0]
            when :start_element
              el = build_context.add_element(event[1])
              event[2].each do |key, value|
                el.attributes[key] = Attribute.new(key, value, el)
              end
              build_context = el
            when :end_element
              build_context = build_context.parent
            when :text
              if build_context[-1].instance_of?(Text)
                build_context[-1] << event[1]
              else
                build_context.add(
                  Text.new(event[1], build_context.whitespace, nil, true)
                ) unless build_context.ignore_whitespace_nodes and
                          event[1].strip.empty?
              end
            when :comment
              build_context.add(Comment.new(event[1]))
            when :cdata
              build_context.add(CData.new(event[1]))
            when :processing_instruction
              build_context.add(Instruction.new(event[1], event[2]))
            else
              raise ParseException.new(
                "Unexpected event while parsing XML fragment: #{event[0].inspect}",
                @parser.source)
            end
          end
        rescue REXML::ParseException
          raise
        rescue
          raise ParseException.new($!.message, @parser.source, @parser, $!)
        end

        unless build_context.equal?(@holder)
          path = begin
                   build_context.expanded_name
                 rescue
                   nil
                 end
          message = "Malformed XML fragment: Missing end tag"
          message += " for '#{path}'" if path
          raise ParseException.new(message, @parser.source)
        end

        @holder.children.each { |child| child.parent = nil }
      end

      private

      # Gives the internal holder the namespace declarations visible at the
      # context element. The context element itself is never touched; the
      # declarations live on a throwaway element that is never serialized.
      def seed_holder_namespaces( context )
        context.namespaces.each do |prefix, uri|
          name = prefix == "xmlns" ? "xmlns" : "xmlns:#{prefix}"
          @holder.add_attribute(name, uri)
        end
      end
    end
  end
end
