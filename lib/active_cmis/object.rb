module ActiveCMIS
  class Object
    include Internal::Caching

    attr_reader :repository, :used_parameters
    attr_reader :key
    alias id key

    def initialize(repository, data, parameters)
      @repository = repository
      @data = data

      @updated_attributes = []

      if @data.nil?
        # Creating a new type from scratch
        raise Error::Constraint.new("This type is not creatable") unless self.class.creatable
        @key = parameters["id"]
        @allowable_actions = {}
        @parent_folders = [] # start unlinked
      else
        @key = parameters["id"] || attribute('cmis:objectId')
        @self_link = data.xpath("at:link[@rel = 'self']/@href", NS::COMBINED).first
        @self_link = @self_link.text
      end
      @used_parameters = parameters
      # FIXME: decide? parameters to use?? always same ? or parameter with reload ?
    end

    def method_missing(method, *parameters)
      string = method.to_s
      if string[-1] == ?=
        assignment = true
        string = string[0..-2]
      end
      if attributes.keys.include? string
        if assignment
          update(string => parameters.first)
        else
          attribute(string)
        end
      elsif self.class.attribute_prefixes.include? string
        if assignment
          raise NotImplementedError.new("Mass assignment not yet supported to prefix")
        else
          @attribute_prefix ||= {}
          @attribute_prefix[method] ||= AttributePrefix.new(self, string)
        end
      else
        super
      end
    end

    def inspect
      "#<#{self.class.inspect} @key=#{key}>"
    end

    def name
      attribute('cmis:name')
    end
    cache :name

    attr_reader :updated_attributes

    def attribute(name)
      attributes[name]
    end

    def attributes
      self.class.attributes.inject({}) do |hash, (key, attr)|
        if data.nil?
          if key == "cmis:objectTypeId"
            hash[key] = self.class.id
          else
            hash[key] = nil
          end
        else
          properties = data.xpath("cra:object/c:properties", NS::COMBINED)
          values = attr.extract_property(properties)
          hash[key] = if values.nil? || values.empty?
                        if attr.repeating
                          []
                        else
                          nil
                        end
                      elsif attr.repeating
                        values.map do |value|
                          attr.property_type.cmis2rb(value)
                        end
                      else
                        attr.property_type.cmis2rb(values.first)
                      end
        end
        hash
      end
    end
    cache :attributes

    # Updates the given attributes, without saving the document
    # Use save to make these changes permanent and visible outside this instance of the document
    # (other #reload after save on other instances of this document to reflect the changes)
    def update(attributes)
      attributes.each do |key, value|
        if (property = self.class.attributes[key.to_s]).nil?
          raise "You are trying to add an unknown attribute (#{key})"
        else
          property.validate_ruby_value(value)
        end
      end
      self.updated_attributes.concat(attributes.keys).uniq!
      self.attributes.merge!(attributes)
    end

    # WARNING: because of the way CMIS is constructed the save operation is not atomic if updates happen to different aspects of the object
    # (parent folders, attributes, content stream, acl), we can't work around this because there is no transaction in CMIS either
    def save
      # FIXME: find a way to handle errors?
      # FIXME: what if multiple objects are created in the course of a save operation?
      result = self
      updated_aspects.each do |hash|
        result = result.send(hash[:message], *hash[:parameters])
      end
      result
    end

    def allowable_actions
      actions = {}
      _allowable_actions.children.map do |node|
        actions[node.name.sub("can", "")] = case t = node.text
                                            when "true", "1"; true
                                            when "false", "0"; false
                                            else t
                                            end
      end
      actions
    end
    cache :allowable_actions

    # :section: Relationships
    # FIXME: this needs to be Folder and Document only

    def target_relations
      query = "at:link[@rel = '#{Rel[repository.cmis_version][:relationships]}']/@href"
      link = data.xpath(query, NS::COMBINED)
      if link.length == 1
        link = Internal::Utils.append_parameters(link.text, "relationshipDirection" => "target", "includeSubRelationshipTypes" => true)
        Collection.new(repository, link)
      else
        raise "Expected exactly 1 relationships link for #{key}, got #{link.length}, are you sure this is a document/folder?"
      end
    end
    cache :target_relations

    def source_relations
      query = "at:link[@rel = '#{Rel[repository.cmis_version][:relationships]}']/@href"
      link = data.xpath(query, NS::COMBINED)
      if link.length == 1
        link = Internal::Utils.append_parameters(link.text, "relationshipDirection" => "source", "includeSubRelationshipTypes" => true)
        Collection.new(repository, link)
      else
        raise "Expected exactly 1 relationships link for #{key}, got #{link.length}, are you sure this is a document/folder?"
      end
    end
    cache :source_relations

    # :section: ACL
    # All 4 subtypes can have an acl
    def acl
      if repository.acls_readable? && allowable_actions["GetACL"]
        # FIXME: actual query should perhaps look at CMIS version before deciding which relation is applicable?
        query = "at:link[@rel = '#{Rel[repository.cmis_version][:acl]}']/@href"
        link = data.xpath(query, NS::COMBINED)
        if link.length == 1
          Acl.new(repository, self, link.first.text, data.xpath("cra:object/c:acl", NS::COMBINED))
        else
          raise "Expected exactly 1 acl for #{key}, got #{link.length}"
        end
      end
    end

    # :section: Fileable

    # Depending on the repository there can be more than 1 parent folder
    # Always returns [] for relationships, policies may also return []
    def parent_folders
      parent_feed = Internal::Utils.extract_links(data, 'up', 'application/atom+xml','type' => 'feed')
      unless parent_feed.empty?
        Collection.new(repository, parent_feed.first)
      else
        parent_entry = Internal::Utils.extract_links(data, 'up', 'application/atom+xml','type' => 'entries')
        unless parent_entry.empty?
          e = conn.get_atom_entry(parent_entry.first)
          [ActiveCMIS::Object.from_atom_entry(repository, e)]
        else
          []
        end
      end
    end
    cache :parent_folders

    def file(folder)
      raise Error::Constraint.new("Filing not supported for objects of type: #{self.class.id}") unless self.class.fileable
      @original_parent_folders ||= parent_folders.dup
      if repository.capabilities["MultiFiling"]
        @parent_folders << folder
      else
        @parent_folders = [folder]
      end
    end

    # FIXME: should throw exception if folder is not actually in @parent_folders?
    def unfile(folder = nil)
      raise Error::Constraint.new("Filing not supported for objects of type: #{self.class.id}") unless self.class.fileable
      @original_parent_folders ||= parent_folders.dup
      if repository.capabilities["UnFiling"]
        if folder.nil?
          @parent_folders = []
        else
          @parent_folders.delete(folder)
        end
      elsif @parent_folders.length > 1
        @parent_folders.delete(folder)
      else
        raise Error::NotSupported.new("Unfiling not supported for this repository")
      end
    end

    def reload
      if @self_link.nil?
        raise "Can't reload unsaved object"
      else
        __reload
        @updated_attributes = []
        @original_parent_folders = nil
      end
    end

    private
    def self_link(options = {})
      url = @self_link
      if options.empty?
        url
      else
        Internal::Utils.append_parameters(url, options)
      end
      #repository.object_by_id_url(options.merge("id" => id))
    end

    def data
      parameters = {"includeAllowableActions" => true, "renditionFilter" => "*", "includeACL" => true}
      data = conn.get_atom_entry(self_link(parameters))
      @used_parameters = parameters
      data
    end
    cache :data

    def conn
      @repository.conn
    end

    def _allowable_actions
      if actions = data.xpath('cra:object/c:allowableActions', NS::COMBINED).first
        actions
      else
        links = data.xpath("at:link[@rel = '#{Rel[repository.cmis_version][:allowableactions]}']/@href", NS::COMBINED)
        if link = links.first
          conn.get_xml(link.text)
        else
          nil
        end
      end
    end

    # Optional parameters:
    #   - properties: a hash key/definition pairs of properties to be rendered (defaults to all attributes)
    #   - attributes: a hash key/value pairs used to determine the values rendered (defaults to self.attributes)
    def render_atom_entry(properties = self.class.attributes, attributes = self.attributes, options = {})
      builder = Nokogiri::XML::Builder.new do |xml|
        xml.entry(NS::COMBINED) do
          xml.parent.namespace = xml.parent.namespace_definitions.detect {|ns| ns.prefix == "at"}
          xml["at"].author do
            xml["at"].name conn.user # FIXME: find reliable way to set author?
          end
          xml["cra"].object do
            xml["c"].properties do
              properties.each do |key, definition|
                definition.render_property(xml, attributes[key])
              end
            end
          end
        end
      end
      builder.to_xml
    end

    attr_writer :updated_attributes
    def updated_aspects(checkin = nil)
      result = []

      if key.nil?
        result << {:message => :save_new_object, :parameters => []}
        if parent_folders.length > 1
          # We started from 0 folders, we already added the first when creating the document

          # Note: to keep a save operation at least somewhat atomic this might be better done  in save_new_object
          result << {:message => :save_folders, :parameters => [parent_folders]}
        end
      else
        if !updated_attributes.empty?
          result << {:message => :save_attributes, :parameters => [updated_attributes, attributes, checkin]}
        end
        if @original_parent_folders
          result << {:message => :save_folders, :parameters => [parent_folders, checkin && !updated_attributes]}
        end
      end
      if acl && acl.updated # We need to be able to do this for newly created documents and merge the two
        result << {:message => :save_acl, :parameters => [acl]}
      end

      if result.empty? && checkin
        # NOTE: this needs some thinking through: in particular this may not work well if there would be an updated content stream
        result << {:message => :save_attributes, :parameters => [[], [], checkin]}
      end

      result
    end

    def save_new_object
      if self.class.required_attributes.any? {|a, _| attribute(a).nil? }
        raise Error::InvalidArgument.new("Not all required attributes are filled in")
      end

      properties = self.class.attributes.reject do |key, definition|
        !updated_attributes.include?(key) && !definition.required
      end
      body = render_atom_entry(properties, attributes, :create => true)

      url = create_url
      response = conn.post(create_url, body, "Content-Type" => "application/atom+xml;type=entry")
      # XXX: Currently ignoring Location header in response

      response_data = Nokogiri::XML::parse(response).xpath("at:entry", NS::COMBINED) # Assume that a response indicates success?

      @self_link = response_data.xpath("at:link[@rel = 'self']/@href", NS::COMBINED).first
      @self_link = @self_link.text
      reload
      @key  = attribute("cmis:objectId")

      self
    end

    def save_attributes(attributes, values, checkin = nil)
      if attributes.empty? && checkin.nil?
        raise "Error: saving attributes but nothing to do"
      end
      properties = self.class.attributes.reject {|key,_| !updated_attributes.include?(key)}
      body = render_atom_entry(properties, values)

      if checkin.nil?
        parameters = {}
      else
        checkin, major, comment = *checkin
        parameters = {"checkin" => checkin}
        if checkin
          parameters.merge! "major" => !!major, "checkinComment" => Internal::Utils.escape_url_parameter(comment)

          if properties.empty?
            # The standard specifies that we can have an empty body here, that does not seem to be true for OpenCMIS
            # body = ""
          end
        end
      end

      # NOTE: Spec says Entity Tag should be used for changeTokens, that does not seem to work
      if ct = attribute("cmis:changeToken")
        parameters.merge! "changeToken" => Internal::Utils.escape_url_parameter(ct)
      end

      uri = self_link(parameters)
      response = conn.put(uri, body)

      data = Nokogiri::XML.parse(response).xpath("at:entry", NS::COMBINED)
      if data.xpath("cra:object/c:properties/c:propertyId[@propertyDefinitionId = 'cmis:objectId']/c:value", NS::COMBINED).text == id
        reload
        @data = data
        self
      else
        reload # Updated attributes should be forgotten here
        ActiveCMIS::Object.from_atom_entry(repository, data)
      end
    end

    def save_folders(requested_parent_folders, checkin = nil)
      current = parent_folders.to_a
      future  = requested_parent_folders.to_a

      common_folders = future.map {|f| f.id}.select {|id| current.any? {|f| f.id == id } }

      added  = future.select {|f1| current.all? {|f2| f1.id != f2.id } }
      removed = current.select {|f1| future.all? {|f2| f1.id != f2.id } }

      # NOTE: an absent atom:content is important here according to the spec, for the moment I did not suffer from this
      body = render_atom_entry("cmis:objectId" => self.class.attributes["cmis:objectId"])

      # Note: change token does not seem to matter here
      # FIXME: currently we assume the data returned by post is not important, I'm not sure that this is always true
      if added.empty?
        removed.each do |folder|
          url = repository.unfiled.url
          url = Internal::Utils.append_parameters(url, "removeFrom" => Internal::Utils.escape_url_parameter(removed.id))
          conn.post(url, body, "Content-Type" => "application/atom+xml;type=entry")
        end
      elsif removed.empty?
        added.each do |folder|
          conn.post(folder.items.url, body, "Content-Type" => "application/atom+xml;type=entry")
        end
      else
        removed.zip(added) do |r, a|
          url = a.items.url
          url = Internal::Utils.append_parameters(url, "sourceFolderId" => Internal::Utils.escape_url_parameter(r.id))
          conn.post(url, body, "Content-Type" => "application/atom+xml;type=entry")
        end
        if extra = added[removed.length..-1]
          extra.each do |folder|
            conn.post(folder.items.url, body, "Content-Type" => "application/atom+xml;type=entry")
          end
        end
      end

      self
    end

    def save_acl(acl)
      acl.save
      reload
      self
    end

    class << self
      attr_reader :repository

      def from_atom_entry(repository, data, parameters = {})
        query = "cra:object/c:properties/c:propertyId[@propertyDefinitionId = '%s']/c:value"
        type_id = data.xpath(query % "cmis:objectTypeId", NS::COMBINED).text
        klass = repository.type_by_id(type_id)
        if klass
          if klass <= self
            klass.new(repository, data, parameters)
          else
            raise "You tried to do from_atom_entry on a type which is not a supertype of the type of the document you identified"
          end
        else
          raise "The object #{extract_property(data, "String", 'cmis:name')} has an unrecognized type #{type_id}"
        end
      end

      def from_parameters(repository, parameters)
        url = repository.object_by_id_url(parameters)
        data = repository.conn.get_atom_entry(url)
        from_atom_entry(repository, data, parameters)
      end

      def attributes(inherited = false)
        {}
      end

      def key
        raise NotImplementedError
      end

    end
  end
end
