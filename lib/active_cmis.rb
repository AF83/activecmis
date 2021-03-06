require 'nokogiri'
require 'net/http'
require 'net/https'
require 'yaml'
require 'logger'
require 'active_cmis/version'
require 'active_cmis/internal/caching'
require 'active_cmis/internal/connection'
require 'active_cmis/exceptions'
require 'active_cmis/server'
require 'active_cmis/repository'
require 'active_cmis/object'
require 'active_cmis/document'
require 'active_cmis/folder'
require 'active_cmis/policy'
require 'active_cmis/relationship'
require 'active_cmis/type'
require 'active_cmis/atomic_types'
require 'active_cmis/property_definition'
require 'active_cmis/collection.rb'
require 'active_cmis/rendition.rb'
require 'active_cmis/acl.rb'
require 'active_cmis/acl_entry.rb'
require 'active_cmis/ns'
require 'active_cmis/active_cmis'
require 'active_cmis/internal/utils'
require 'active_cmis/rel'
require 'active_cmis/attribute_prefix'
require 'active_cmis/query_result'
