# frozen_string_literal: true
require_relative 'default'

module REXML
  module Formatters
    # Pretty-prints an XML document.  By default this destroys whitespace in
    # text nodes and will insert carriage returns and indentations.
    #
    # Mixed content (elements interleaved with text, such as
    # <tt><p>Hello <b>bold</b> world</p></tt>) cannot be re-indented without
    # changing the meaning of the document.  Setting #preserve_content to
    # +true+ keeps every character sequence of such content exactly as it was
    # parsed: indentation and newlines are only inserted between the children
    # of an element whose content is purely element children, and elements
    # containing significant text or CDATA are written on a single line.
    #
    # When #preserve_content is enabled, the special +xml:space+ attribute is
    # honored and inherited from ancestor elements:
    #
    # - <tt>xml:space="preserve"</tt> forbids inserting or collapsing
    #   whitespace, both on the element and on all of its descendants.
    # - <tt>xml:space="default"</tt> restores the normal rules for the
    #   element and its descendants, ending an inherited +preserve+ scope.
    # - Any other value is invalid and raises an ArgumentError when the
    #   element carrying it is written.
    #
    # With #preserve_content left as +false+ (the default) the formatter
    # behaves exactly as before.
    #
    # TODO: Add an option to print attributes on new lines
    class Pretty < Default

      # If compact is set to true, then the formatter will attempt to use as
      # little space as possible
      attr_accessor :compact
      # The width of a page.  Used for formatting text
      attr_accessor :width
      # When true, mixed content and +xml:space="preserve"+ regions are written
      # verbatim instead of having their whitespace reflowed.  Defaults to
      # false, which preserves the historical behavior of this formatter.
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
        @inline = false
      end

      protected
      def write_element(node, output)
        output << ' '*@level unless @inline
        output << "<#{node.expanded_name}"

        node.attributes.each_attribute do |attr|
          output << " "
          attr.write( output )
        end unless node.attributes.empty?

        # Validate the effective xml:space mode even for empty elements,
        # where the content classification below is never reached.
        space_state = preserve_content ? xml_space_state(node) : nil

        if node.children.empty?
          if @ie_hack
            output << " "
          end
          output << "/"
        else
          output << ">"
          # An element nested in verbatim content stays verbatim itself, so
          # that its own start/end tags never introduce newlines into the
          # parent's character sequence.
          inline = @inline ||
                   (preserve_content &&
                    (space_state == :preserve || mixed_content?(node)))
          # If compact and all children are text, and if the formatted output
          # is less than the specified width, then try to print everything on
          # one line
          skip = false
          if !inline && compact
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
            if inline
              write_inline_children(node, output,
                                    space_state == :preserve)
            else
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
          end
          output << "</#{node.expanded_name}"
        end
        output << ">"
      end

      # Writes the children of +node+ without inserting any whitespace of our
      # own.  Text, CDATA, comments and processing instructions are written
      # verbatim and in document order.  Element children inherit the
      # verbatim mode, except that an inner xml:space="default" ends an
      # inherited preserve scope; such an element gets its normal block
      # layout again.  A mixed-content parent never reaches the block branch
      # because its element children are classified as mixed content
      # themselves.
      #
      # Whitespace-only text adjacent to a block island belongs to the
      # restored-whitespace region rather than to the preserved character
      # sequence, so it is dropped just like ordinary indentation; this keeps
      # repeated formatting from accumulating blank lines.
      def write_inline_children(node, output, parent_preserves)
        was_inline = @inline
        @inline = true
        children = node.children
        # In a mixed-content parent the element children are adjacent to
        # significant text, so every child is serialized verbatim; only a
        # purely-preserved parent may carve out block islands for descendants
        # that switch xml:space back to "default".
        if parent_preserves && !mixed_content?(node)
          children.each_with_index do |child, index|
            if block_island?(child)
              write_block_child(child, output)
            elsif text_node?(child)
              write_island_neighbor_text(child, children, index, output)
            else
              write(child, output)
            end
          end
        else
          children.each { |child| write(child, output) }
        end
      ensure
        @inline = was_inline
      end

      # Writes a text node that may sit next to a block island.  The newlines
      # and indentation inserted around the island are layout we added rather
      # than preserved content, so a whitespace-only run adjacent to the
      # island is swallowed by its surrounding newlines, and whitespace that
      # merely leads (or trails) significant text on the same node is trimmed.
      # Significant character data is always kept verbatim.
      def write_island_neighbor_text(child, children, index, output)
        string = child.to_s
        before_island = block_island?(children[index + 1])
        after_island = block_island?(children[index - 1])
        if before_island
          string = string.sub(/\s+\z/, "")
        end
        if after_island
          string = string.sub(/\A\s+/, "")
        end
        output << string
      end

      # True when an element child re-enables normal whitespace handling
      # inside an inherited xml:space="preserve" region.
      def block_island?(child)
        child.respond_to?(:node_type) &&
          child.node_type == :element && xml_space_state(child) == :default
      end

      def text_node?(child)
        child.is_a?(Text) && !child.is_a?(CData)
      end

      # Writes a single element child that has escaped an inherited
      # xml:space="preserve" scope through an inner xml:space="default".
      # @inline is already false, so the element renders with the normal
      # block rules, including dropping indentation-only text nodes: that
      # whitespace belongs to a region where whitespace handling was
      # explicitly restored, and keeping it would make repeated formatting
      # grow extra blank lines.
      def write_block_child(child, output)
        inline_was = @inline
        @inline = false
        output << "\n"
        @level += @indentation
        write(child, output)
        output << "\n"
        @level -= @indentation
        output << ' '*@level
      ensure
        @inline = inline_was
      end

      def write_text( node, output )
        if @inline
          output << node.to_s
          return
        end
        # Not gsub!/squeeze!: Text#to_s returns the node's own string.
        s = node.to_s().gsub(/\s/, ' ').squeeze(" ")
        s = wrap(s, @width - @level)
        s = indent_text(s, @level, " ", true)
        output << (' '*@level + s)
      end

      def write_comment( node, output)
        output << ' ' * @level unless @inline
        super
      end

      def write_cdata( node, output)
        output << ' ' * @level unless @inline
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
      # Resolves the effective xml:space mode of +node+ by walking the
      # ancestor chain, so that inner "default" declarations can cancel an
      # inherited "preserve".  Returns :default, :preserve or nil when the
      # attribute is never set.  Raises ArgumentError on an invalid value.
      def xml_space_state(node)
        ancestor = node
        while ancestor
          if ancestor.respond_to?(:attributes)
            value = ancestor.attributes["xml:space"]
            unless value.nil?
              case value
              when "preserve"
                return :preserve
              when "default"
                return :default
              else
                raise ArgumentError,
                      "invalid xml:space value: #{value.inspect} " +
                      "(must be \"preserve\" or \"default\")"
              end
            end
          end
          ancestor = ancestor.parent
        end
        nil
      end

      # True when the element contains significant character data interleaved
      # with its other children.  Every child is inspected; checking only the
      # first child would miss trailing text, CDATA or character data that
      # follows comments or processing instructions.
      def mixed_content?(node)
        node.children.any? do |child|
          case child
          when CData
            true
          when Text
            significant_text?(child)
          else
            false
          end
        end
      end

      # True when a text node carries character data that must survive
      # formatting.  Whitespace introduced only for source indentation is
      # insignificant, but whitespace expanded from character or general
      # entity references (e.g. "&#x20;") is part of the document content and
      # must be preserved.
      def significant_text?(text)
        return true unless text.value.strip.empty?
        text.to_s =~ /&(?:#\d+|#x[0-9a-fA-F]+|[A-Za-z_][\w.-]*);/
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
