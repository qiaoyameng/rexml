# frozen_string_literal: true

module REXML
  # Canonicalizes XML documents and element subtrees into a deterministic
  # sequence of UTF-8 bytes.
  #
  # Two explicit modes are supported:
  #
  # [C14N::CANONICAL_XML_1_1 (+:c14n11+)]
  #   Inclusive canonicalization as specified by
  #   {Canonical XML Version 1.1}[https://www.w3.org/TR/xml-c14n11/].
  #   In-scope namespace declarations of ancestors are copied to the apex
  #   element when canonicalizing a subtree, as are inherited attributes in
  #   the +xml+ namespace (+xml:base+, +xml:lang+, +xml:space+, ...).
  # [C14N::EXCLUSIVE_XML_CANONICALIZATION_1_0 (+:exc_c14n+)]
  #   Exclusive canonicalization as specified by
  #   {Exclusive XML Canonicalization Version 1.0}[https://www.w3.org/TR/xml-exc-c14n/].
  #   Only namespace prefixes that are visibly utilized by the node set
  #   (plus any prefixes given via +inclusive_prefixes+) are rendered, so a
  #   signed subtree stays valid when inserted into a different document.
  #
  # Both modes sort namespace declarations and attributes, escape text and
  # attribute values, write empty elements as paired start/end tags, and
  # include comments and processing instructions outside the document root
  # (comments only when requested).  The input DOM is never modified, and
  # external entities are never resolved (no network access is performed).
  #
  #   require "rexml/document"
  #   doc = REXML::Document.new('<b z="1" y="2"></b>')
  #   REXML::C14N.canonicalize(doc) # => '<b y="2" z="1"></b>'
  #   doc.canonicalize(mode: :exc_c14n, comments: true)
  module C14N
    # Mode selecting Canonical XML 1.1 (inclusive canonicalization).
    CANONICAL_XML_1_1 = :c14n11
    # Mode selecting Exclusive XML Canonicalization 1.0.
    EXCLUSIVE_XML_CANONICALIZATION_1_0 = :exc_c14n

    # The namespace URI bound to the +xml+ prefix.  It is implicitly bound
    # and must never be declared in canonical output.
    XML_NAMESPACE_URI = "http://www.w3.org/XML/1998/namespace"

    # Raised when a node cannot be canonicalized.
    class Error < StandardError; end

    TEXT_ESCAPES = {
      "&" => "&amp;",
      "<" => "&lt;",
      ">" => "&gt;",
      "\r" => "&#xD;",
    }.freeze
    ATTRIBUTE_ESCAPES = {
      "&" => "&amp;",
      "<" => "&lt;",
      '"' => "&quot;",
      "\t" => "&#x9;",
      "\n" => "&#xA;",
      "\r" => "&#xD;",
    }.freeze

    # Canonicalizes +node+ (a REXML::Document or REXML::Element) and
    # returns the canonical form as a UTF-8 encoded String.
    #
    # mode:: C14N::CANONICAL_XML_1_1 (default) or
    #        C14N::EXCLUSIVE_XML_CANONICALIZATION_1_0.
    # comments:: when true, comment nodes are included in the output.
    # inclusive_prefixes:: array of namespace prefixes that exclusive
    #                      canonicalization must treat as inclusively
    #                      canonicalized (the +InclusiveNamespaces+
    #                      +PrefixList+).  Use +"#default"+ for the default
    #                      namespace.  Only valid in exclusive mode.
    def self.canonicalize(node,
                          mode: CANONICAL_XML_1_1,
                          comments: false,
                          inclusive_prefixes: nil)
      Canonicalizer.new(mode, comments, inclusive_prefixes).canonicalize(node)
    end

    # :stopdoc:
    class Canonicalizer
      def initialize(mode, comments, inclusive_prefixes)
        case mode
        when CANONICAL_XML_1_1, EXCLUSIVE_XML_CANONICALIZATION_1_0
          @mode = mode
        else
          raise ArgumentError,
                "unknown canonicalization mode: #{mode.inspect} " \
                "(expected #{CANONICAL_XML_1_1.inspect} or " \
                "#{EXCLUSIVE_XML_CANONICALIZATION_1_0.inspect})"
        end
        if inclusive_prefixes && @mode != EXCLUSIVE_XML_CANONICALIZATION_1_0
          raise ArgumentError,
                "inclusive_prefixes is only valid with " \
                "#{EXCLUSIVE_XML_CANONICALIZATION_1_0.inspect}"
        end
        @with_comments = comments
        @inclusive_prefixes = (inclusive_prefixes || []).map do |prefix|
          prefix == "#default" ? "" : prefix.to_s
        end
        @output = +""
      end

      def canonicalize(node)
        case node
        when Document
          canonicalize_document(node)
        when Element
          canonicalize_subtree(node)
        else
          raise Error,
                "cannot canonicalize #{node.class}; " \
                "expected REXML::Document or REXML::Element"
        end
        @output.force_encoding(::Encoding::UTF_8)
      end

      private

      def exclusive?
        @mode == EXCLUSIVE_XML_CANONICALIZATION_1_0
      end

      def canonicalize_document(document)
        document.children.each do |child|
          case child
          when Element
            render_element(child, {}, [], true)
          when Comment
            render_comment(child) if @with_comments
          when Instruction
            render_instruction(child)
          end
          # The XML declaration, the document type declaration, and
          # whitespace text outside the document root are not part of the
          # canonical form.
        end
      end

      def canonicalize_subtree(element)
        rendered_namespaces = {}
        inherited_attributes = []
        unless exclusive?
          parent = element.parent
          if parent.is_a?(Element)
            # Ancestor declarations form the document context of the
            # subtree: they are inherited by the apex element, and a
            # default namespace undeclaration (xmlns="") in the subtree
            # must cancel them.
            rendered_namespaces = namespace_map(parent.namespaces)
          end
          inherited_attributes = ancestor_xml_attributes(element)
        end
        render_element(element, rendered_namespaces, inherited_attributes, true)
      end

      # Converts a REXML namespace hash ({"xmlns" => uri, "p" => uri}) into
      # a prefix => uri map ({"" => uri, "p" => uri}).
      def namespace_map(namespaces)
        map = {}
        namespaces.each do |prefix, uri|
          map[prefix == "xmlns" ? "" : prefix] = uri
        end
        map
      end

      # Attributes in the xml namespace (xml:base, xml:lang, xml:space, ...)
      # inherited from ancestors of the subtree root.  The nearest ancestor
      # wins, and attributes defined on the apex element itself are not
      # duplicated.
      def ancestor_xml_attributes(element)
        own = []
        element.attributes.each_attribute do |attribute|
          own << attribute.expanded_name if attribute.prefix == "xml"
        end
        inherited = {}
        ancestor = element.parent
        while ancestor.is_a?(Element)
          ancestor.attributes.each_attribute do |attribute|
            next unless attribute.prefix == "xml"
            name = attribute.expanded_name
            next if own.include?(name) || inherited.key?(name)
            inherited[name] = attribute
          end
          ancestor = ancestor.parent
        end
        inherited.values
      end

      def render_element(element, rendered_namespaces, inherited_attributes,
                         apex)
        in_scope = namespace_map(element.namespaces)
        declarations = if exclusive?
          exclusive_declarations(element, in_scope, rendered_namespaces, apex)
        else
          inclusive_declarations(in_scope, rendered_namespaces, apex)
        end
        child_rendered = rendered_namespaces.merge(declarations)

        @output << "<" << element.expanded_name
        render_namespace_declarations(declarations)
        render_attributes(element, inherited_attributes)
        @output << ">"
        element.children.each do |child|
          case child
          when Element
            render_element(child, child_rendered, [], false)
          when CData, Text
            @output << escape_text(child.value)
          when Comment
            render_comment(child) if @with_comments
          when Instruction
            render_instruction(child)
          when Entity
            raise Error,
                  "cannot canonicalize unexpanded entity " \
                  "<#{child.name.inspect}>; expand it before canonicalizing"
          end
        end
        @output << "</" << element.expanded_name << ">"
      end

      # Inclusive canonicalization: render every in-scope declaration that
      # differs from what the already-rendered ancestors produced.  This
      # also emits xmlns="" when the default namespace is undeclared.
      # At the apex of a subtree the complete in-scope context is rendered,
      # since no ancestor declaration appears in the output.
      def inclusive_declarations(in_scope, rendered_namespaces, apex)
        declarations = {}
        in_scope.each do |prefix, uri|
          if apex
            # An absent declaration and an empty one are equivalent for
            # the default namespace: xmlns="" is only rendered to cancel
            # a non-empty default namespace declared by an ancestor.
            unless prefix.empty? && uri.to_s.empty? &&
                   rendered_namespaces[prefix].to_s.empty?
              declarations[prefix] = uri
            end
          elsif rendered_namespaces[prefix].to_s != uri.to_s
            declarations[prefix] = uri
          end
        end
        declarations
      end

      # Exclusive canonicalization: render only declarations for prefixes
      # that are visibly utilized by the element and its attributes, plus
      # the prefixes of the InclusiveNamespaces PrefixList at the apex.
      def exclusive_declarations(element, in_scope, rendered_namespaces,
                                 apex)
        needed = []
        prefix = element.prefix
        if prefix.nil? || prefix.empty?
          needed << ""
        else
          needed << prefix
        end
        element.attributes.each_attribute do |attribute|
          next if attribute.namespace_declaration?
          attribute_prefix = attribute.prefix
          next if attribute_prefix.nil? || attribute_prefix.empty?
          needed << attribute_prefix
        end
        needed |= @inclusive_prefixes if apex

        declarations = {}
        needed.each do |needed_prefix|
          next if needed_prefix == "xml"
          uri = in_scope[needed_prefix]
          if uri.nil?
            next unless needed_prefix.empty?
            uri = ""
          end
          if rendered_namespaces[needed_prefix].to_s != uri
            declarations[needed_prefix] = uri
          end
        end
        declarations
      end

      def render_namespace_declarations(declarations)
        declarations.sort_by { |prefix, _uri| prefix }.each do |prefix, uri|
          if prefix.empty?
            @output << ' xmlns="'
          else
            @output << " xmlns:" << prefix << '="'
          end
          @output << escape_attribute(uri) << '"'
        end
      end

      def render_attributes(element, inherited_attributes)
        attributes = []
        # Effective attributes include default values from the DTD, as
        # required for canonicalization of a validated document.
        element.attributes.send(:each_effective_attribute) do |attribute|
          next if attribute.namespace_declaration?
          attributes << attribute
        end
        attributes.concat(inherited_attributes)
        attributes.sort_by! { |attribute| attribute_sort_key(attribute) }
        attributes.each do |attribute|
          @output << " " << attribute.expanded_name << '="'
          @output << escape_attribute(attribute.value) << '"'
        end
      end

      # Attributes sort lexicographically by (namespace URI, local name);
      # attributes in no namespace sort first.
      def attribute_sort_key(attribute)
        if attribute.prefix == "xml"
          [XML_NAMESPACE_URI, attribute.name]
        else
          [attribute.namespace.to_s, attribute.name]
        end
      end

      def render_comment(comment)
        @output << "<!--" << comment.string << "-->"
      end

      def render_instruction(instruction)
        @output << "<?" << instruction.target
        content = instruction.content
        @output << " " << content if content && !content.empty?
        @output << "?>"
      end

      def escape_text(string)
        string.gsub(/[&<>\r]/, TEXT_ESCAPES)
      end

      def escape_attribute(string)
        string.gsub(/[&<"\t\n\r]/, ATTRIBUTE_ESCAPES)
      end
    end
    # :startdoc:
  end

  class Document
    # Canonicalizes this document; see REXML::C14N.canonicalize.
    def canonicalize(mode: C14N::CANONICAL_XML_1_1,
                     comments: false,
                     inclusive_prefixes: nil)
      C14N.canonicalize(self,
                        mode: mode,
                        comments: comments,
                        inclusive_prefixes: inclusive_prefixes)
    end
  end

  class Element
    # Canonicalizes the subtree rooted at this element; see
    # REXML::C14N.canonicalize.
    def canonicalize(mode: C14N::CANONICAL_XML_1_1,
                     comments: false,
                     inclusive_prefixes: nil)
      C14N.canonicalize(self,
                        mode: mode,
                        comments: comments,
                        inclusive_prefixes: inclusive_prefixes)
    end
  end
end
