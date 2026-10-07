# frozen_string_literal: false
require_relative "parent"
require_relative "element"

module REXML
  # Represents a parsed XML fragment: an ordered list of sibling nodes
  # (elements, text, comments and processing instructions) that is not
  # required to have a single root element.
  #
  # A DocumentFragment is created by REXML::Document.parse_fragment;
  # it carries the namespace bindings that were visible at the parse
  # context, so that prefixed names inside the fragment keep resolving
  # to the same namespace URIs.  The fragment itself is independent:
  # it belongs to no document and modifying it never touches the
  # context it was parsed against.
  #
  # Note that REXML resolves namespaces dynamically from the ancestors
  # of an element.  When you move a node out of a fragment into another
  # tree, the namespace bindings of the fragment do not travel with it;
  # declare the needed namespaces explicitly on the new location
  # (for example with Element#add_namespace) instead of renaming the
  # node, so that its expanded name is preserved:
  #
    #   fragment = REXML::Document.parse_fragment("<x:a/>", context: context_element)
    #   child = fragment.children.first
  #   target.add_namespace("x", child.namespace("x"))
  #   target.add_element(child)
  class DocumentFragment < Parent
    # :call-seq:
    #   new(namespaces = {}) -> new_fragment
    #
    # Returns a new empty fragment that inherits the given namespace
    # bindings.  +namespaces+ maps prefixes to URIs, using the key
    # "xmlns" for the default namespace (the same shape as
    # Element#namespaces).
    def initialize( namespaces = {} )
      super()
      @inherited_namespaces = {}
      namespaces.each do |prefix, uri|
        @inherited_namespaces[prefix.to_s] = uri
      end
    end

    # :call-seq:
    #   node_type -> :document_fragment
    def node_type
      :document_fragment
    end

    # :call-seq:
    #   namespaces -> hash_of_inherited_namespaces
    #
    # Returns a hash of the namespace bindings inherited from the parse
    # context.  The hash is a copy; modifying it does not affect the
    # fragment.
    def namespaces
      @inherited_namespaces.dup
    end

    # :call-seq:
    #   prefixes -> array_of_inherited_prefixes
    #
    # Returns the prefixes inherited from the parse context, not
    # including the default namespace declaration.
    def prefixes
      @inherited_namespaces.keys - ["xmlns"]
    end

    # :call-seq:
    #   namespace(prefix = nil) -> string_uri or nil
    #
    # Returns the namespace URI inherited from the parse context for
    # +prefix+, or the URI of the default namespace when +prefix+ is
    # nil.  Returns nil when no such binding was inherited.
    def namespace( prefix = nil )
      prefix = "xmlns" if prefix.nil? or prefix == ""
      prefix = prefix.delete_prefix("xmlns:") unless prefix == "xmlns"
      @inherited_namespaces[prefix]
    end

    # :call-seq:
    #   add_element(name) -> new_element
    #
    # Creates an element named +name+, adds it as the last child of the
    # fragment and returns it.
    def add_element( name )
      element = Element.new(name)
      add(element)
      element
    end

    # Fragments do not belong to a document.
    def document
      nil
    end

    # :call-seq:
    #   write(output = $stdout, indent = -1, transitive = false, ie_hack = false)
    #
    # Writes each child of the fragment, in order, to +output+.
    # See Document#write for the meaning of the arguments.
    def write( output = $stdout, indent = -1, transitive = false, ie_hack = false )
      formatter = if indent > -1
        if transitive
          require_relative "formatters/transitive"
          REXML::Formatters::Transitive.new( indent, ie_hack )
        else
          require_relative "formatters/pretty"
          REXML::Formatters::Pretty.new( indent, ie_hack )
        end
      else
        REXML::Formatters::Default.new( ie_hack )
      end
      each do |child|
        formatter.write( child, output )
      end
    end

    # :call-seq:
    #   to_s -> string
    #
    # Returns the fragment serialized as a string.
    def to_s
      output = ""
      write(output)
      output
    end

    # Used by Element to resolve namespaces through the parent chain.
    def _calculate_namespaces( cache_hash = nil, attlist_mappings = nil ) # :nodoc:
      return cache_hash[self] if cache_hash && cache_hash.key?(self)
      namespaces = @inherited_namespaces.dup
      cache_hash[self] = namespaces if cache_hash
      namespaces
    end

    # TreeParser hooks: fragments do not perform whitespace handling.
    def whitespace # :nodoc:
      false
    end

    def ignore_whitespace_nodes # :nodoc:
      false
    end
  end
end
