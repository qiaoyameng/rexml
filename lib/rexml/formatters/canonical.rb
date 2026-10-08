# frozen_string_literal: false

require "uri"
require_relative "default"

module REXML
  module Formatters
    # Abstract canonical XML formatter.
    class Canonical < Default
      XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"

      def initialize(with_comments = false)
        super(false)
        @with_comments = with_comments
      end

      def write(node, output)
        result = +""
        result.force_encoding(::Encoding::UTF_8)
        super(node, result)
        result.force_encoding(::Encoding::UTF_8)
        output << result
      end

      protected

      def write_document(node, output)
        node.children.each do |child|
          case child
          when Element
            write(child, output)
          when Instruction
            write_instruction(child, output)
          when Comment
            write_comment(child, output) if @with_comments
          end
        end
      end

      def write_element(node, output)
        stack = [
          {
            event: :start, node: node,
            rendered: initial_physical_rendered_namespaces(node),
            in_scope: initial_in_scope_namespaces(node),
            subtree_root: true
          }
        ]

        until stack.empty?
          frame = stack.pop
          current = frame[:node]
          case frame[:event]
          when :end
            frame[:rendered].replace(frame[:parent_rendered])
            output << "</#{current.expanded_name}>"
          when :child
            write(current, output)
          when :start
            parent_rendered = frame[:rendered].dup
            rendered_frame = process_element_start(
              current, output, frame[:rendered], frame[:in_scope],
              frame[:subtree_root]
            )
            children = current.children
            if children.empty?
              output << ">"
              output << "</#{current.expanded_name}>"
              next
            end

            output << ">"
            stack << {
              event: :end, node: current,
              rendered: rendered_frame,
              parent_rendered: parent_rendered
            }
            children.reverse_each do |child|
              case child
              when Element
                stack << {
                  event: :start, node: child,
                  rendered: rendered_frame,
                  in_scope: frame[:in_scope].dup
                    .merge(own_namespaces(current))
                    .merge(own_namespaces(child)),
                  subtree_root: false
                }
              else
                next if child.is_a?(Comment) && !@with_comments
                stack << {event: :child, node: child}
              end
            end
          end
        end
      end

      def write_text(node, output)
        write_canonical_text(node, output)
      end

      def write_cdata(node, output)
        write_canonical_text(node, output)
      end

      def write_comment(node, output)
        output << Comment::START
        output << node.to_s
        output << Comment::STOP
      end

      def write_instruction(node, output)
        output << Instruction::START
        output << node.target
        if node.content
          output << " "
          output << node.content
        end
        output << Instruction::STOP
      end

      private


      def process_element_start(node, output, rendered, in_scope, subtree_root)
        frame = rendered.dup
        output << "<#{node.expanded_name}"
        write_namespaces(node, frame, in_scope, subtree_root, output)
        write_attributes(node, frame, subtree_root, output)
        frame
      end

      def write_namespaces(node, rendered, in_scope, subtree_root, output)
        candidates = namespace_candidates(node, in_scope, subtree_root)

        sort_namespace_candidates(candidates).each do |prefix, origin, uri|
          next unless render_namespace?(node, prefix, uri, origin,
                                        rendered, in_scope, subtree_root)

          write_namespace(prefix, uri, output)
          rendered[prefix] = uri
        end
      end

      def namespace_candidates(node, in_scope, subtree_root)
        candidate_prefixes =
          if subtree_root
            subtree_rendered_prefixes(node, in_scope)
          else
            non_subtree_inherited_namespace_prefixes(node, in_scope)
          end
        candidates = candidate_prefixes.map do |prefix, uri|
          [prefix, :inherited, uri]
        end
        own_namespaces(node).each do |prefix, uri|
          existing = candidates.find { |candidate| candidate[0] == prefix }
          if existing.nil?
            candidates << [prefix, :declared, uri]
          else
            existing[1] = :declared
            existing[2] = uri
          end
        end
        candidates
      end

      def non_subtree_inherited_namespace_prefixes(node, in_scope)
        {}
      end

      def subtree_rendered_prefixes(node, in_scope)
        in_scope.select do |prefix, _uri|
          prefix == "xmlns" ?
            subtree_uses_default_namespace?(node) :
            subtree_uses_prefix?(node, prefix)
        end
      end

      def subtree_uses_prefix?(node, prefix)
        visible_prefixes(node).include?(prefix) ||
          descendants_visible_prefixes(node).include?(prefix)
      end

      def subtree_uses_default_namespace?(node)
        node.prefix.empty? ||
          node.children.any? { |child| descendant_uses_default_namespace?(child) }
      end

      def descendant_uses_default_namespace?(node)
        case node
        when Element
          node.prefix.empty? ||
            node.children.any? { |child| descendant_uses_default_namespace?(child) }
        else
          false
        end
      end

      def render_namespace?(node, prefix, uri, origin, rendered,
                            in_scope, subtree_root)
        return false if prefix == "xml"

        if prefix == "xmlns"
          render_default_namespace?(node, uri, origin, rendered,
                                    subtree_root)
        else
          rendered[prefix] != uri
        end
      end

      def render_default_namespace?(node, uri, origin, rendered, subtree_root)
        if uri.empty?
          node.prefix.empty? &&
            (!rendered.fetch("xmlns", "").empty? ||
             initial_in_scope_namespaces(node).fetch("xmlns", "").length > 0)
        else
          rendered["xmlns"] != uri
        end
      end

      def write_attributes(node, rendered, subtree_root, output)
        attributes = explicit_attributes(node)
        inherited_attributes(node, subtree_root).each do |name, value|
          existing = attributes.find { |attribute| attribute.expanded_name == name }
          if existing
            replacement = existing.clone
            replacement.normalized = value
            attributes[attributes.index(existing)] = replacement
          else
            attributes << SyntheticAttribute.new(name, value)
          end
        end

        attributes.sort_by do |attribute|
          attribute_sort_key(attribute)
        end.each do |attribute|
          output << " "
          output << write_attribute(attribute)
        end
      end

      def inherited_attributes(node, subtree_root)
        {}
      end

      def explicit_attributes(node)
        node.attributes.each_attribute.reject(&:namespace_declaration?)
      end

      def attribute_sort_key(attribute)
        if attribute.is_a?(SyntheticAttribute) || attribute.prefix == "xml"
          [XML_NAMESPACE, attribute.name]
        else
          [attribute.namespace.to_s, attribute.name, attribute.prefix]
        end
      end

      def write_attribute(attribute)
        output_name =
          if attribute.is_a?(SyntheticAttribute)
            attribute.name
          else
            attribute.expanded_name
          end
        value = canonical_attribute_object_value(attribute)
        "#{output_name}=\"#{canonical_attribute_value(value)}\""
      end

      def canonical_attribute_object_value(attribute)
        if attribute.is_a?(SyntheticAttribute)
          attribute.value
        else
          unnormalize_attribute(attribute)
        end
      end

      def unnormalize_attribute(attribute)
        Text.unnormalize(attribute.to_s, attribute.doctype)
      end

      def write_namespace(prefix, uri, output)
        name = prefix == "xmlns" ? "xmlns" : "xmlns:#{prefix}"
        output << " #{name}=\"#{canonical_attribute_value(uri)}\""
      end

      def write_canonical_text(node, output)
        value = canonical_text_value(node)
        value = value.gsub("&", "&amp;")
                     .gsub("<", "&lt;")
                     .gsub(">", "&gt;")
                     .gsub("\r", "&#xD;")
        output << value
      end

      def canonical_text_value(node)
        value = node.value
        value = value.gsub(/&#x([0-9a-fA-F]+);/) { [$1.to_i(16)].pack("U") }
                     .gsub(/&#([0-9]+);/) { [$1.to_i].pack("U") }
        value
      end

      def canonical_attribute_value(value)
        value = value.to_s.dup
        value.gsub!("&", "&amp;")
        value.gsub!("<", "&lt;")
        value.gsub!("\"", "&quot;")
        value.gsub!("\r", "&#xD;")
        value.gsub!("\t", "&#x9;")
        value.gsub!("\n", "&#xA;")
        value
      end

      def initial_physical_rendered_namespaces(node)
        {"xml" => XML_NAMESPACE}
      end

      def initial_in_scope_namespaces(node)
        ancestors(node).inject({"xml" => XML_NAMESPACE}) do |namespaces, ancestor|
          namespaces.merge(own_namespaces(ancestor))
        end
      end

      def ancestors(node)
        ancestors = []
        current = node.parent
        while current.is_a?(Element) && !current.is_a?(Document)
          ancestors.unshift(current)
          current = current.parent
        end
        ancestors
      end

      def own_namespaces(node)
        namespaces = {}
        node.attributes.each_attribute do |attribute|
          next unless attribute.namespace_declaration?
          prefix = attribute.expanded_name == "xmlns" ? "xmlns" : attribute.name
          namespaces[prefix] = attribute.value
        end
        namespaces
      end

      def sort_namespace_candidates(candidates)
        candidates.sort_by do |prefix, origin, _uri|
          [namespace_prefix_order(prefix), prefix, origin]
        end
      end

      def namespace_prefix_order(prefix)
        prefix == "xmlns" ? 0 : 1
      end

      def visible_prefixes(node)
        prefixes = []
        prefixes << node.prefix unless node.prefix.nil? || node.prefix.empty?
        node.attributes.each_attribute do |attribute|
          next if attribute.namespace_declaration?
          prefix = attribute.prefix
          prefixes << prefix unless prefix.nil? || prefix.empty?
        end
        prefixes.uniq
      end

      def descendants_visible_prefixes(node)
        prefixes = []
        stack = node.children.dup
        until stack.empty?
          current = stack.pop
          case current
          when Element
            prefixes << current.prefix unless current.prefix.empty?
            current.attributes.each_attribute do |attribute|
              next if attribute.namespace_declaration?
              prefix = attribute.prefix
              prefixes << prefix unless prefix.nil? || prefix.empty?
            end
            stack.concat(current.children)
          end
        end
        prefixes.uniq
      end

      class SyntheticAttribute
        attr_reader :name, :value

        def initialize(name, value)
          @name = name
          @value = value
        end

        def prefix
          "xml"
        end
      end
    end

    # Serializes a document or element subset as Canonical XML 1.0.
    #
    # Pass +true+ to the first argument to include comments.
    class CanonicalXML1_0 < Canonical
      private

      def initial_rendered_namespaces(node)
        initial_in_scope_namespaces(node)
      end

      def initial_physical_rendered_namespaces(node)
        {"xml" => XML_NAMESPACE}
      end
    end

    # Serializes a document or element subset as Canonical XML 1.1.
    #
    # In addition to Canonical XML 1.0, serializing an element subset
    # accounts for inherited +xml:base+ and +xml:lang+ attributes.
    # Pass +true+ to the first argument to include comments.
    class CanonicalXML1_1 < CanonicalXML1_0
      private

      def inherited_attributes(node, subtree_root)
        return {} unless subtree_root

        attributes = {}
        unless node.attributes["xml:lang"]
          ancestors(node).reverse_each do |ancestor|
            lang = ancestor.attributes["xml:lang"]
            if lang
              attributes["xml:lang"] = lang unless lang.empty?
              break
            end
          end
        end

        own_base = node.attributes["xml:base"]
        if ancestors(node).any? { |ancestor| ancestor.attributes["xml:base"] } || own_base.nil?
          base_parts = ancestors(node).map do |ancestor|
            ancestor.attributes["xml:base"]
          end.compact
          base_parts << own_base if own_base
          if base_parts.any?
            base = base_parts.inject(nil) do |resolved, part|
              if resolved.nil?
                part
              else
                begin
                  URI.join(resolved, part).to_s
                rescue URI::Error
                  part
                end
              end
            end
            attributes["xml:base"] = base unless base.nil? || base.empty?
          end
        end

        attributes
      end
    end
    CanonicalXML11 = CanonicalXML1_1
    C14N1_1 = CanonicalXML1_1

    # Serializes a document or element subset as Exclusive XML
    # Canonicalization 1.0.
    #
    # +inclusive_namespace_prefixes+ is the InclusiveNamespaces PrefixList.
    # It may be an Array of prefixes, a whitespace separated String, or
    # +nil+. Use +"#default"+ to place the default namespace in the
    # inclusive prefix list. Pass +true+ to the first argument to include
    # comments.
    class ExclusiveXMLCanonicalization1_0 < Canonical
      def initialize(with_comments = false, inclusive_namespace_prefixes = nil)
        super(with_comments)
        @inclusive_namespace_prefixes =
          normalize_inclusive_namespaces(inclusive_namespace_prefixes)
      end

      private

      def normalize_inclusive_namespaces(prefixes)
        case prefixes
        when nil
          []
        when String
          prefixes.split(/\s+/)
        else
          prefixes.to_a
        end.map { |prefix| prefix == "#default" ? "xmlns" : prefix }
      end

      def initial_rendered_namespaces(node)
        {"xml" => XML_NAMESPACE}
      end

      def subtree_rendered_prefixes(node, in_scope)
        prefixes = visible_prefixes(node) +
                   descendants_visible_prefixes(node) +
                   @inclusive_namespace_prefixes
        prefixes << "xmlns" if node.prefix.empty?
        exclusive_prefixes(node, in_scope, prefixes, true)
      end

      def exclusive_prefixes(node, in_scope, prefixes, subtree_root)
        prefixes.uniq.map do |prefix|
          if @inclusive_namespace_prefixes.include?(prefix)
            uri = in_scope[prefix] || own_namespaces(node)[prefix]
          else
            uri = in_scope[prefix] || own_namespaces(node)[prefix]
          end
          [prefix, uri] if uri
        end.compact.to_h
      end

      def render_namespace?(node, prefix, uri, origin, rendered,
                            in_scope, subtree_root)
        return false if prefix == "xml"

        if prefix == "xmlns"
          if uri.empty?
            return node.prefix.empty? &&
              (!rendered["xmlns"].to_s.empty? ||
               initial_in_scope_namespaces(node).fetch("xmlns", "").length > 0)
          end
          listed = @inclusive_namespace_prefixes.include?("xmlns")
          return rendered["xmlns"] != uri &&
                 (node.prefix.empty? || listed)
        end

        rendered[prefix] != uri &&
          (visible_here?(node, prefix) ||
           @inclusive_namespace_prefixes.include?(prefix))
      end

      def visible_here?(node, prefix)
        node.prefix == prefix ||
          node.attributes.each_attribute.any? do |attribute|
            !attribute.namespace_declaration? && attribute.prefix == prefix
          end
      end

      def non_subtree_inherited_namespace_prefixes(node, in_scope)
        prefixes = visible_prefixes(node)
        if node.prefix.empty? && !in_scope.fetch("xmlns", "").empty?
          prefixes << "xmlns"
        end
        prefixes.uniq.map do |prefix|
          uri = in_scope[prefix]
          [prefix, uri] if uri
        end.compact.to_h
      end

    end
    ExclusiveC14N = ExclusiveXMLCanonicalization1_0
  end
end
