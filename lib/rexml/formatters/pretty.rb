# frozen_string_literal: true
require_relative 'default'

module REXML
  module Formatters
    # Pretty-prints an XML document.  This destroys whitespace in text nodes
    # and will insert carriage returns and indentations.
    #
    # TODO: Add an option to print attributes on new lines
    class Pretty < Default

      # If compact is set to true, then the formatter will attempt to use as
      # little space as possible
      attr_accessor :compact
      # The width of a page.  Used for formatting text
      attr_accessor :width
      # If preserve_content is set to true, then the formatter only
      # re-indents elements whose content is pure element content (child
      # elements, comments, and processing instructions, separated by
      # whitespace-only text).  Elements with mixed content -- character
      # data interleaved with child nodes -- are written out unchanged,
      # character for character.  CDATA sections and text that expands to
      # whitespace only through entity references (such as +&#32;+) count
      # as character data.  +xml:space+ is honored: it is inherited from
      # ancestors, "preserve" forbids inserting or removing whitespace in
      # the subtree, and an inner "default" restores the normal rules.
      # Any other +xml:space+ value raises ArgumentError.  Defaults to
      # false, which keeps the historical whitespace-destroying behavior.
      attr_accessor :preserve_content

      # Create a new pretty printer.
      #
      # output::
      #   An object implementing '<<(String)', to which the output will be written.
      # indentation::
      #   An integer greater than 0.  The indentation of each level will be
      #   this number of spaces.  If this is < 1, the behavior of this object
      #   is undefined.  Defaults to 2.
      # ie_hack::
      #   If true, the printer will insert whitespace before closing empty
      #   tags, thereby allowing Internet Explorer's XML parser to
      #   function. Defaults to false.
      def initialize( indentation=2, ie_hack=false )
        @indentation = indentation
        @level = 0
        @ie_hack = ie_hack
        @width = 80
        @compact = false
        @preserve_content = false
      end

      protected
      def write_element(node, output)
        if @preserve_content
          write_element_preserving_content(node, output)
          return
        end
        output << ' '*@level
        output << "<#{node.expanded_name}"

        node.attributes.each_attribute do |attr|
          output << " "
          attr.write( output )
        end unless node.attributes.empty?

        if node.children.empty?
          if @ie_hack
            output << " "
          end
          output << "/"
        else
          output << ">"
          # If compact and all children are text, and if the formatted output
          # is less than the specified width, then try to print everything on
          # one line
          skip = false
          if compact
            if node.children.inject(true) {|s,c| s & c.kind_of?(Text)}
              string = +""
              old_level = @level
              @level = 0
              node.children.each { |child| write( child, string ) }
              @level = old_level
              if string.length < @width
                output << string
                skip = true
              end
            end
          end
          unless skip
            output << "\n"
            @level += @indentation
            node.children.each { |child|
              next if child.kind_of?(Text) and child.to_s.strip.length == 0
              write( child, output )
              output << "\n"
            }
            @level -= @indentation
            output << ' '*@level
          end
          output << "</#{node.expanded_name}"
        end
        output << ">"
      end

      # Writes an element without touching its character data.  Only
      # pure element content is re-indented; mixed content and
      # +xml:space="preserve"+ subtrees are written out exactly as they
      # are.  No leading indentation is written; the caller decides.
      def write_element_preserving_content(node, output)
        output << "<#{node.expanded_name}"

        node.attributes.each_attribute do |attr|
          output << " "
          attr.write( output )
        end unless node.attributes.empty?

        if node.children.empty?
          output << " " if @ie_hack
          output << "/"
        else
          output << ">"
          if element_content_only?(node) and !xml_space_preserve?(node)
            output << "\n"
            @level += @indentation
            node.children.each { |child|
              next if child.instance_of?(Text) and child.to_s.strip.empty?
              output << ' '*@level
              write_preserving_child( child, output )
              output << "\n"
            }
            @level -= @indentation
            output << ' '*@level
          else
            node.children.each { |child|
              write_preserving_child( child, output )
            }
          end
          output << "</#{node.expanded_name}"
        end
        output << ">"
      end

      # Writes a child node without altering its character data.  Child
      # elements are formatted recursively, so pure element content is
      # still re-indented inside mixed content.
      def write_preserving_child(node, output)
        case node
        when Element
          write_element_preserving_content(node, output)
        when CData
          output << CData::START
          output << node.to_s
          output << CData::STOP
        when Comment
          output << Comment::START
          output << node.to_s
          output << Comment::STOP
        when Instruction
          write_instruction(node, output)
        when Text
          output << node.to_s
        else
          write(node, output)
        end
      end

      def write_text( node, output )
        # Not gsub!/squeeze!: Text#to_s returns the node's own string.
        s = node.to_s().gsub(/\s/, ' ').squeeze(" ")
        s = wrap(s, @width - @level)
        s = indent_text(s, @level, " ", true)
        output << (' '*@level + s)
      end

      def write_comment( node, output)
        output << ' ' * @level
        super
      end

      def write_cdata( node, output)
        output << ' ' * @level
        super
      end

      def write_document( node, output )
        # Ok, this is a bit odd.  All XML documents have an XML declaration,
        # but it may not write itself if the user didn't specifically add it,
        # either through the API or in the input document.  If it doesn't write
        # itself, then we don't need a carriage return... which makes this
        # logic more complex.
        node.children.each { |child|
          next if child.instance_of?(Text)
          unless child == node.children[0] or child.instance_of?(Text) or
            (child == node.children[1] and !node.children[0].writethis)
            output << "\n"
          end
          write( child, output )
        }
      end

      private
      # An element's content is pure element content when every child is
      # an element, a comment, or a processing instruction, or a text
      # node containing nothing but literal whitespace.  CDATA sections
      # and text that expands to whitespace only through entity
      # references (such as +&#32;+) are character data and make the
      # content mixed.  Every child is checked; the first child alone
      # doesn't decide.
      def element_content_only?(node)
        node.children.all? do |child|
          case child
          when Element, Comment, Instruction
            true
          when CData
            false
          when Text
            child.to_s.strip.empty?
          else
            false
          end
        end
      end

      # Returns true if +node+ is in the scope of an
      # +xml:space="preserve"+ attribute.  The nearest ancestor-or-self
      # carrying +xml:space+ decides; "default" restores the normal
      # rules.  Any other value is invalid and raises ArgumentError.
      def xml_space_preserve?(node)
        current = node
        while current.is_a?(Element)
          value = current.attributes["xml:space"]
          if value
            case value
            when "preserve"
              return true
            when "default"
              return false
            else
              raise ArgumentError,
                    "invalid xml:space value #{value.inspect} on element " \
                    "<#{current.expanded_name}>: " \
                    "must be \"default\" or \"preserve\""
            end
          end
          current = current.parent
        end
        false
      end

      def indent_text(string, level=1, style="\t", indentfirstline=true)
        return string if level < 0
        string.gsub(/\n/, "\n#{style*level}")
      end

      def wrap(string, width)
        parts = []
        while string.length > width and place = string.rindex(' ', width)
          parts << string[0...place]
          string = string[place+1..-1]
        end
        parts << string
        parts.join("\n")
      end

    end
  end
end

