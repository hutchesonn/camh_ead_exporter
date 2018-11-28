# encoding: utf-8
require 'nokogiri'
require 'securerandom'
require 'cgi'
require 'time'

require_relative 'lib/singularize_extents'

class EADSerializer < ASpaceExport::Serializer
  serializer_for :ead

  # Allow plugins to hook in to record processing by providing their own
  # serialization step (a class with a 'call' method accepting the arguments
  # defined in `run_serialize_step`.
  def self.add_serialize_step(serialize_step)
    @extra_serialize_steps ||= []
    @extra_serialize_steps << serialize_step
  end

  def self.run_serialize_step(data, xml, fragments, context)
    Array(@extra_serialize_steps).each do |step|
      step.new.call(data, xml, fragments, context)
    end
  end


  def prefix_id(id)
    if id.nil? or id.empty? or id == 'null'
      #""
	  nil
    elsif id =~ /^#{@id_prefix}/
      #id
	  nil
    else
      #"#{@id_prefix}#{id}"
	  nil
    end
  end

  def xml_errors(content)
    # there are message we want to ignore. annoying that java xml lib doesn't
    # use codes like libxml does...
    ignore = [ /Namespace prefix .* is not defined/, /The prefix .* is not bound/  ]
    ignore = Regexp.union(ignore)
    # the "wrap" is just to ensure that there is a psuedo root element to eliminate a "false" error
    Nokogiri::XML("<wrap>#{content}</wrap>").errors.reject { |e| e.message =~ ignore  }
  end

  # ANW-716: We may have content with a mix of loose '&' chars that need to be escaped, along with pre-escaped HTML entities
  # Example:
  # c                 => "This is the &lt; test & for the <title>Sanford &amp; Son</title>
  # escape_content(c) => "This is the &lt; test &amp; for the <title>Sanford &amp; Son</title>
  # we want to leave the pre-escaped entities alone, and escape the loose & chars

  def escape_content(content)
    # first, find any pre-escaped entities and "mark" them by replacing & with @@
    # so something like &lt; becomes @@lt;
    # and &#1234 becomes @@#1234

    content.gsub!(/&\w+;/) {|t| t.gsub('&', '@@')}
    content.gsub!(/&#\d{4}/) {|t| t.gsub('&', '@@')}
    content.gsub!(/&#\d{3}/) {|t| t.gsub('&', '@@')}

    # now we know that all & characters remaining are not part of some pre-escaped entity, and we can escape them safely
    content.gsub!('&', '&amp;')

    # 'unmark' our pre-escaped entities
    content.gsub!(/@@\w+;/) {|t| t.gsub('@@', '&')}
    content.gsub!(/@@#\d{4}/) {|t| t.gsub('@@', '&')}
    content.gsub!(/@@#\d{3}/) {|t| t.gsub('@@', '&')}

    return content
  end


  def handle_linebreaks(content)
    # 4archon... 
    content.gsub!("\n\t", "\n\n")  
    # if there's already p tags, just leave as is
    return content if ( content.strip =~ /^<p(\s|\/|>)/ or content.strip.length < 1 )
    original_content = content
    blocks = content.split("\n\n").select { |b| !b.strip.empty? }
    if blocks.length > 1
      content = blocks.inject("") do |c,n| 
        c << "<p>#{escape_content(n.chomp)}</p>"  
      end
    else
      content = "<p>#{escape_content(content.strip)}</p>"
    end

    # just return the original content if there's still problems
    xml_errors(content).any? ? original_content : content
  end

  def strip_p(content)
    content.gsub("<p>", "").gsub("</p>", "").gsub("<p/>", '')
  end

  def remove_smart_quotes(content)
    content = content.gsub(/\xE2\x80\x9C/, '"').gsub(/\xE2\x80\x9D/, '"').gsub(/\xE2\x80\x98/, "\'").gsub(/\xE2\x80\x99/, "\'")
  end

  def sanitize_mixed_content(content, context, fragments, allow_p = false  )
#    return "" if content.nil?

    # remove smart quotes from text
    content = remove_smart_quotes(content)

    # br's should be self closing
    content = content.gsub("<br>", "<br/>").gsub("</br>", '')
    # lets break the text, if it has linebreaks but no p tags.

    if allow_p
      content = handle_linebreaks(content)
    else
      content = strip_p(content)
    end

    begin
      if ASpaceExport::Utils.has_html?(content)
        context.text (fragments << content )
      else
        context.text content.gsub("&amp;", "&") #thanks, Nokogiri
      end
    rescue
      context.cdata content
    end
  end

  def stream(data)
    @stream_handler = ASpaceExport::StreamHandler.new
    @fragments = ASpaceExport::RawXMLHandler.new
    @include_unpublished = data.include_unpublished?
    @include_daos = data.include_daos?
    @use_numbered_c_tags = data.use_numbered_c_tags?
    @id_prefix = I18n.t('archival_object.ref_id_export_prefix', :default => 'aspace_')

    doc = Nokogiri::XML::Builder.new(:encoding => "UTF-8") do |xml|
      begin

      ead_attributes = {
        'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
        'xsi:schemaLocation' => 'urn:isbn:1-931666-22-9 http://www.loc.gov/ead/ead.xsd',
        'xmlns:xlink' => 'http://www.w3.org/1999/xlink'
      }

      if data.publish === false
        ead_attributes['audience'] = 'internal'
      end

      xml.ead( ead_attributes ) {

        xml.text (
          @stream_handler.buffer { |xml, new_fragments|
            serialize_eadheader(data, xml, new_fragments)
          })

        atts = {:level => data.level, :otherlevel => data.other_level}
        atts.reject! {|k, v| v.nil?}

        xml.archdesc(atts) {

          xml.did {


            if (val = data.language)
              xml.langmaterial {
                xml.language(:langcode => val) {
                  xml.text I18n.t("enumerations.language_iso639_2.#{val}", :default => val)
                }
              }
            end

            if (val = data.repo.name)
			  repo_atts = {
			    :label => "Repository:",
				:encodinganalog => "852$a"
			  }
              xml.repository(repo_atts) {
                xml.corpname { sanitize_mixed_content(val, xml, @fragments) }
              }
            end

            if (val = data.title)
			  unittitle_atts = {
			    :label => "Title:",
				:encodinganalog => "245"
			  }
              xml.unittitle(unittitle_atts)  {   sanitize_mixed_content(val, xml, @fragments) }
            end

            serialize_origination(data, xml, @fragments)

            unitid_atts = {
				:countrycode => "US",
				:repositorycode => "TxU-TH",
				:encodinganalog => "099",
				:label => "Identification:"
			}
            xml.unitid(unitid_atts) { xml.text data.send("id_0") }

            if @include_unpublished
              data.external_ids.each do |exid|
                xml.unitid  ({ "audience" => "internal", "type" => exid['source'], "identifier" => exid['external_id']}) { xml.text exid['external_id']}
              end
            end

            serialize_extents(data, xml, @fragments, level="resource")

            serialize_dates(data, xml, @fragments)

            serialize_did_notes(data, xml, @fragments)

            data.instances_with_sub_containers.each do |instance|
              serialize_container(instance, xml, @fragments)
            end

            EADSerializer.run_serialize_step(data, xml, @fragments, :did)

          }# </did>

          data.digital_objects.each do |dob|
            serialize_digital_object(dob, xml, @fragments)
          end

          serialize_nondid_notes(data, xml, @fragments)

          serialize_bibliographies(data, xml, @fragments)

          serialize_indexes(data, xml, @fragments)

          serialize_controlaccess(data, xml, @fragments)

          EADSerializer.run_serialize_step(data, xml, @fragments, :archdesc)

          xml.dsc {

            data.children_indexes.each do |i|
              xml.text(
                       @stream_handler.buffer {|xml, new_fragments|
                         serialize_child(data.get_child(i), xml, new_fragments)
                       }
                       )
            end
          }
        }
      }

    rescue => e
      xml.text  "ASPACE EXPORT ERROR : YOU HAVE A PROBLEM WITH YOUR EXPORT OF YOUR RESOURCE. THE FOLLOWING INFORMATION MAY HELP:\n
                MESSAGE: #{e.message.inspect}  \n
                TRACE: #{e.backtrace.inspect} \n "
    end



    end
    doc.doc.root.add_namespace nil, 'urn:isbn:1-931666-22-9'

    Enumerator.new do |y|
      @stream_handler.stream_out(doc, @fragments, y)
    end


  end

  # this extracts <head> content and returns it. optionally, you can provide a
  # backup text node that will be returned if there is no <head> nodes in the
  # content
  def extract_head_text(content, backup = "")
    content ||= ""
    match = content.strip.match(/<head( [^<>]+)?>(.+?)<\/head>/)
    if match.nil? # content has no head so we return it as it
      return [content, backup ]
    else
      [ content.gsub(match.to_a.first, ''), match.to_a.last]
    end
  end

  def serialize_child(data, xml, fragments, c_depth = 1)
    begin
    return if data["publish"] === false && !@include_unpublished
    return if data["suppressed"] === true

    tag_name = @use_numbered_c_tags ? :"c#{c_depth.to_s.rjust(2, '0')}" : :c

    atts = {:level => data.level, :otherlevel => data.other_level, :id => prefix_id(data.ref_id)}

    if data.publish === false
      atts[:audience] = 'internal'
    end

    atts.reject! {|k, v| v.nil?}
    xml.send(tag_name, atts) {

      xml.did {
        if (val = data.title)
          xml.unittitle {  sanitize_mixed_content( val,xml, fragments) }
        end

        if !data.component_id.nil? && !data.component_id.empty?
          xml.unitid data.component_id
        end

        if @include_unpublished
          data.external_ids.each do |exid|
            xml.unitid  ({ "audience" => "internal",  "type" => exid['source'], "identifier" => exid['external_id']}) { xml.text exid['external_id']}
          end
        end

        serialize_origination(data, xml, fragments)
        serialize_extents(data, xml, fragments, level="child")
        serialize_dates(data, xml, fragments)
        serialize_did_notes(data, xml, fragments)

        EADSerializer.run_serialize_step(data, xml, fragments, :did)

        data.instances_with_sub_containers.each do |instance|
          serialize_container(instance, xml, @fragments)
        end

        if @include_daos
          data.instances_with_digital_objects.each do |instance|
            serialize_digital_object(instance['digital_object']['_resolved'], xml, fragments)
          end
        end
      }

      serialize_nondid_notes(data, xml, fragments)

      serialize_bibliographies(data, xml, fragments)

      serialize_indexes(data, xml, fragments)

      serialize_controlaccess(data, xml, fragments)

      EADSerializer.run_serialize_step(data, xml, fragments, :archdesc)

      data.children_indexes.each do |i|
        xml.text(
                 @stream_handler.buffer {|xml, new_fragments|
                   serialize_child(data.get_child(i), xml, new_fragments, c_depth + 1)
                 }
                 )
      end
    }
    rescue => e
      xml.text "ASPACE EXPORT ERROR : YOU HAVE A PROBLEM WITH YOUR EXPORT OF ARCHIVAL OBJECTS. THE FOLLOWING INFORMATION MAY HELP:\n
                MESSAGE: #{e.message.inspect}  \n
                TRACE: #{e.backtrace.inspect} \n "
    end
  end


  def serialize_origination(data, xml, fragments)
    unless data.creators_and_sources.nil?
      data.creators_and_sources.each do |link|
        agent = link['_resolved']
        role = link['role']
        relator = link['relator']
        sort_name = agent['display_name']['sort_name']
        rules = agent['display_name']['rules']
        source = agent['display_name']['source']
        authfilenumber = agent['display_name']['authority_id']
        node_name = case agent['agent_type']
                    when 'agent_person'; 'persname'
                    when 'agent_family'; 'famname'
                    when 'agent_corporate_entity'; 'corpname'
                    end
        xml.origination(:label => upcase_initial_char(role)) {
         atts = {:role => relator, :source => source, :rules => rules, :authfilenumber => authfilenumber}
		 case node_name
		 when 'corpname'
			encodinganalog = {:encodinganalog => "110"}
			atts.merge!(encodinganalog)
		 else
		    encodinganalog = {:encodinganalog => "100"}
			atts.merge!(encodinganalog)
		 end
         atts.reject! {|k, v| v.nil?}

          xml.send(node_name, atts) {
            sanitize_mixed_content(sort_name, xml, fragments )
          }
        }
      end
    end
  end

  #def serialize_controlaccess(data, xml, fragments)
  #  if (data.controlaccess_subjects.length + data.controlaccess_linked_agents.length) > 0
  #    xml.controlaccess {
  #
  #      data.controlaccess_subjects.each do |node_data|
  #        xml.send(node_data[:node_name], node_data[:atts]) {
  #          sanitize_mixed_content( node_data[:content], xml, fragments, ASpaceExport::Utils.include_p?(node_data[:node_name]) )
  #        }
  #      end
  #
  #
  #      data.controlaccess_linked_agents.each do |node_data|
  #        xml.send(node_data[:node_name], node_data[:atts]) {
  #          sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
  #        }
  #      end
  #
  #    } #</controlaccess>
  #  end
  #end

  #CAMH Custom controlaccess handling.  Splits the control access terms into categories and gives them headers.
  def serialize_controlaccess(data, xml, fragments)
    if (data.controlaccess_subjects.length + data.controlaccess_linked_agents.length) > 0
	  persname = []
	  corpname = []
	  geogname = []
	  subject = []
	  genreform = []
	  famname = []
	  
	  data.controlaccess_subjects.each do |node_data|
	    case node_data[:node_name]
		when 'subject'
			subject.push(node_data)
		when 'genreform'
			genreform.push(node_data)
		when 'geogname'
			geogname.push(node_data)
	    end
	  end
	  
	  data.controlaccess_linked_agents.each do |node_data|
	    case node_data[:node_name]
		when 'persname'
			persname.push(node_data)
		when 'corpname'
			corpname.push(node_data)
		when 'famname'
			famname.push(node_data)
	    end
      end
	  
	  persname = persname.sort_by { |key| key[:content]}
	  corpname = corpname.sort_by { |key| key[:content]}
	  geogname = geogname.sort_by { |key| key[:content]}
	  subject = subject.sort_by { |key| key[:content]}
	  genreform = genreform.sort_by { |key| key[:content]}
	  famname = famname.sort_by { |key| key[:content]}
	  
	  xml.controlaccess {
		  xml.head { 
		    xml.text "Index Terms" 
		  }
		  if (persname.length) > 0
			xml.controlaccess {
			  xml.head { 
				xml.text "Personal Names" 
			  }
			  persname.to_a.each do |node_data|
			    encodinganalog = {:encodinganalog => "600"}
				node_data[:atts].merge!(encodinganalog)
				xml.send(node_data[:node_name], node_data[:atts]) {
				  sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
				}
			  end
			}
		  end
		  
		  if (famname.length) > 0
			xml.controlaccess {
			  xml.head { 
				xml.text "Family Names" 
			  }
			  famname.to_a.each do |node_data|
			    encodinganalog = {:encodinganalog => "600"}
				node_data[:atts].merge!(encodinganalog)
				xml.send(node_data[:node_name], node_data[:atts]) {
				  sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
				}
			  end
			}
		  end
		  
		  if (corpname.length) > 0
			xml.controlaccess {
			  xml.head { 
				xml.text "Corporate Names" 
			  }
			  corpname.to_a.each do |node_data|
			    encodinganalog = {:encodinganalog => "610"}
				node_data[:atts].merge!(encodinganalog)
				xml.send(node_data[:node_name], node_data[:atts]) {
				  sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
				}
			  end
			}
		  end
		  
		  if (subject.length) > 0
			xml.controlaccess {
			  xml.head { 
				xml.text "Subjects" 
			  }
			  subject.to_a.each do |node_data|
			    encodinganalog = {:encodinganalog => "650"}
				node_data[:atts].merge!(encodinganalog)
				xml.send(node_data[:node_name], node_data[:atts]) {
				  sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
				}
			  end
			}
		  end
		  
		  if (geogname.length) > 0
			xml.controlaccess {
			  xml.head { 
				xml.text "Places" 
			  }
			  geogname.to_a.each do |node_data|
			    encodinganalog = {:encodinganalog => "651"}
				node_data[:atts].merge!(encodinganalog)
				xml.send(node_data[:node_name], node_data[:atts]) {
				  sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
				}
			  end
			}
		  end
		  
		  if (genreform.length) > 0
			xml.controlaccess {
			  xml.head { 
				xml.text "Document Types" 
			  }
			  genreform.to_a.each do |node_data|
			    encodinganalog = {:encodinganalog => "655"}
				node_data[:atts].merge!(encodinganalog)
				xml.send(node_data[:node_name], node_data[:atts]) {
				  sanitize_mixed_content( node_data[:content], xml, fragments,ASpaceExport::Utils.include_p?(node_data[:node_name]) )
				}
			  end
			}
		  end
	}
	end
  end
  

  def serialize_subnotes(subnotes, xml, fragments, include_p = true)
    subnotes.each do |sn|
      next if sn["publish"] === false && !@include_unpublished

      audatt = sn["publish"] === false ? {:audience => 'internal'} : {}

      title = sn['title']

      case sn['jsonmodel_type']
      when 'note_text'
        sanitize_mixed_content(sn['content'], xml, fragments, include_p )
      when 'note_chronology'
        xml.chronlist(audatt) {
          xml.head { sanitize_mixed_content(title, xml, fragments) } if title

          sn['items'].each do |item|
            xml.chronitem {
              if (val = item['event_date'])
                xml.date { sanitize_mixed_content( val, xml, fragments) }
              end
              if item['events'] && !item['events'].empty?
                xml.eventgrp {
                  item['events'].each do |event|
                    xml.event { sanitize_mixed_content(event, xml, fragments) }
                  end
                }
              end
            }
          end
        }
      when 'note_orderedlist'
        atts = {:type => 'ordered', :numeration => sn['enumeration']}.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)
        xml.list(atts) {
          xml.head { sanitize_mixed_content(title, xml, fragments) }  if title

          sn['items'].each do |item|
            xml.item { sanitize_mixed_content(item,xml, fragments)}
          end
        }
      when 'note_definedlist'
        xml.list({:type => 'deflist'}.merge(audatt)) {
          xml.head { sanitize_mixed_content(title,xml, fragments) }  if title

          sn['items'].each do |item|
            xml.defitem {
              xml.label { sanitize_mixed_content(item['label'], xml, fragments) } if item['label']
              xml.item { sanitize_mixed_content(item['value'],xml, fragments )} if item['value']
            }
          end
        }
      end
    end
  end


  def serialize_container(inst, xml, fragments)
    atts = {}

    sub = inst['sub_container']
    top = sub['top_container']['_resolved']

    #atts[:id] = prefix_id(SecureRandom.hex)
    #last_id = atts[:id]

	text = ""
    atts[:type] = top['type']
    text = top['indicator']

    atts[:label] = I18n.t("enumerations.instance_instance_type.#{inst['instance_type']}",
                          :default => inst['instance_type'])
    text << " [#{top['barcode']}]" if top['barcode']

    if (cp = top['container_profile'])
      atts[:altrender] = cp['_resolved']['url'] || cp['_resolved']['name']
    end

    xml.container(atts) {
      sanitize_mixed_content(text, xml, fragments)
    }

    (2..3).each do |n|
      atts = {}

      next unless sub["type_#{n}"]

      #atts[:id] = prefix_id(SecureRandom.hex)
      #atts[:parent] = last_id
      #last_id = atts[:id]
	  text = ""

      atts[:type] = sub["type_#{n}"]
      text = sub["indicator_#{n}"]
	  

      xml.container(atts) {
        sanitize_mixed_content(text, xml, fragments)
      }
    end
  end

  # set daoloc audience attr == 'internal' if this is an unpublished && include_unpublished is set
  def get_audience_flag_for_file_version(file_version)
    if file_version['file_uri'] && 
       (file_version['publish'] == false && @include_unpublished)
      return "internal"
    else
      return "external"
    end
  end

  def serialize_digital_object(digital_object, xml, fragments)
    return if digital_object["publish"] === false && !@include_unpublished
    return if digital_object["suppressed"] === true

    # ANW-285: Only serialize file versions that are published, unless include_unpublished flag is set 
    file_versions_to_display = digital_object['file_versions'].select {|fv| fv['publish'] == true || @include_unpublished }

    title = digital_object['title']
    date = digital_object['dates'][0] || {}

    atts = digital_object["publish"] === false ? {:audience => 'internal'} : {}

    content = ""
    content << title if title
    content << ": " if date['expression'] || date['begin']
    if date['expression']
      content << date['expression']
    elsif date['begin']
      content << date['begin']
      if date['end'] != date['begin']
        content << "-#{date['end']}"
      end
    end
    atts['xlink:title'] = digital_object['title'] if digital_object['title']


    if file_versions_to_display.empty?
      atts['xlink:type'] = 'simple'
      atts['xlink:href'] = digital_object['digital_object_id']
      atts['xlink:actuate'] = 'onRequest'
      atts['xlink:show'] = 'new'
      xml.dao(atts) {
        xml.daodesc{ sanitize_mixed_content(content, xml, fragments, true) } if content
      }
    elsif file_versions_to_display.length == 1
      file_version = file_versions_to_display.first

      atts['xlink:type'] = 'simple'
      atts['xlink:actuate'] = file_version['xlink_actuate_attribute'] || 'onRequest'
      atts['xlink:show'] = file_version['xlink_show_attribute'] || 'new'
      atts['xlink:role'] = file_version['use_statement'] if file_version['use_statement']
      atts['xlink:href'] = file_version['file_uri'] 
      atts['xlink:audience'] = get_audience_flag_for_file_version(file_version)
      xml.dao(atts) {
        xml.daodesc{ sanitize_mixed_content(content, xml, fragments, true) } if content
      }
    else
      xml.daogrp( atts.merge( { 'xlink:type' => 'extended'} ) ) {
        xml.daodesc{ sanitize_mixed_content(content, xml, fragments, true) } if content
        file_versions_to_display.each do |file_version|
          atts['xlink:type'] = 'locator'
          atts['xlink:href'] = file_version['file_uri'] 
          atts['xlink:role'] = file_version['use_statement'] if file_version['use_statement']
          atts['xlink:title'] = file_version['caption'] if file_version['caption']
          atts['xlink:audience'] = get_audience_flag_for_file_version(file_version)
          xml.daoloc(atts)
        end
      }
    end
  end


  #def serialize_extents(obj, xml, fragments)
  #  if obj.extents.length
  #    obj.extents.each do |e|
  #      next if e["publish"] === false && !@include_unpublished
  #      audatt = e["publish"] === false ? {:audience => 'internal'} : {}
  #      xml.physdesc({:altrender => e['portion']}.merge(audatt)) {
  #        if e['number'] && e['extent_type']
  #          xml.extent({:altrender => 'materialtype spaceoccupied'}) {
  #            sanitize_mixed_content("#{e['number']} #{I18n.t('enumerations.extent_extent_type.'+e['extent_type'], :default => e['extent_type'])}", xml, fragments)
  #          }
  #        end
  #        if e['container_summary']
  #          xml.extent({:altrender => 'carrier'}) {
  #            sanitize_mixed_content( e['container_summary'], xml, fragments)
  #          }
  #        end
  #        xml.physfacet { sanitize_mixed_content(e['physical_details'],xml, fragments) } if e['physical_details']
  #        xml.dimensions  {   sanitize_mixed_content(e['dimensions'],xml, fragments) }  if e['dimensions']
  #      }
  #    end
  #  end
  #end

  # MODIFCATION: Assemble extents with singularize extents.  Remove the @altrender.
    def serialize_extents(obj, xml, fragments, level)
    extent_statements = []
    if obj.extents.length
      obj.extents.each do |e|
        next if e["publish"] === false && !@include_unpublished
        audatt = e["publish"] === false ? {:audience => 'internal'} : {}
        extent_statement = ''
        extent_number_float = e['number'].to_f
        extent_type = e['extent_type']
		next if extent_number_float == 0.0
        if extent_number_float == 1.0
          extent_type = SingularizeExtents.singularize_extent(extent_type)
        end
		extent_type = prettify_missing_enumeration(extent_type)
        extent_number_and_type = "#{e['number']} #{extent_type}"
        physical_details = []
        physical_details << e['container_summary'] if e['container_summary']
        physical_details << e['physical_details'] if e['physical_details']
        physical_details << e['dimensions'] if e['dimensions']
        physical_detail = physical_details.join('; ')
        if extent_number_and_type && physical_details.length > 0
          extent_statement += extent_number_and_type + ' (' + physical_detail + ')'
        else
          extent_statement += extent_number_and_type
        end
        extent_statements << extent_statement
      end
    end
    
    if extent_statements.length > 0
      if level == "resource"
        extent_statements.each do |content|
            physdesc_atts = {
			:label => "Extent:",
			:encodinganalog => "300"
			}
			xml.physdesc(physdesc_atts) {
                xml.extent {
                  sanitize_mixed_content(content, xml, fragments)  
            }
          }
        end
      elsif level == "child"
       physdesc_atts = {
			:label => "Extent:",
			:encodinganalog => "300"
			}
	   xml.physdesc(physdesc_atts) {
                xml.extent {
                  sanitize_mixed_content(extent_statements.join(', '), xml, fragments)  
            }
          }
      end
    end
  end



  def serialize_dates(obj, xml, fragments)
    date_size = obj.archdesc_dates.length
    obj.archdesc_dates.each.with_index do |node_data, index|
      next if node_data["publish"] === false && !@include_unpublished
      audatt = node_data["publish"] === false ? {:audience => 'internal'} : {}
	  node_data[:atts].merge!(audatt)
	  case node_data[:atts][:type]
	  when "inclusive"
	    encodinganalog = {:encodinganalog => "245$f"}
		node_data[:atts].merge!(encodinganalog)
	  when "bulk"
	    encodinganalog = {:encodinganalog => "245$g"}
		node_data[:atts].merge!(encodinganalog)
	  else
		encodinganalog = {:encodinganalog => "245"}
		node_data[:atts].merge!(encodinganalog)
	  end
	  if index != date_size-1
	    node_data[:content] = customize_ead_data(node_data[:content], ', ')
	  end
      xml.unitdate(node_data[:atts]){
        sanitize_mixed_content( node_data[:content],xml, fragments )
      }
    end
  end

  # To-Do: Clean up note attributes, there has to be a simpler way to add this.
  def serialize_did_notes(data, xml, fragments)
    data.notes.each do |note|
      next if note["publish"] === false && !@include_unpublished
      next unless data.did_note_types.include?(note['type'])

      audatt = note["publish"] === false ? {:audience => 'internal'} : {}
      content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)

      #att = { :id => prefix_id(note['persistent_id']) }.reject {|k,v| v.nil? || v.empty? || v == "null" }
      att ||= {}
	  case note['type']
	  when 'bioghist'
	    encodinganalog = {:encodinganalog => "545"}
	    att.merge!(encodinganalog)
	  when 'scopecontent'
	    encodinganalog = {:encodinganalog => "520"}
	    att.merge!(encodinganalog)
	  when 'abstract'
	    encodinganalog = {:encodinganalog => "520$a"}
	    att.merge!(encodinganalog)
	  when 'accessrestrict'
	    encodinganalog = {:encodinganalog => "506"}
	    att.merge!(encodinganalog)
	  when 'prefercite'
	    encodinganalog = {:encodinganalog => "524"}
	    att.merge!(encodinganalog)
      when 'arrangement'
	    encodinganalog = {:encodinganalog => "351"}
	    att.merge!(encodinganalog)
	  when 'altformavail'
	    encodinganalog = {:encodinganalog => "530"}
	    att.merge!(encodinganalog)
      when 'userestrict'
	    encodinganalog = {:encodinganalog => "540"}
	    att.merge!(encodinganalog)
	  when 'acqinfo'
	    encodinganalog = {:encodinganalog => "541"}
		att.merge!(encodinganalog)
	  when 'relatedmaterial'
	    encodinganalog = {:encodinganalog => "545"}
	    att.merge!(encodinganalog)
	  when 'langmaterial'
	    encodinganalog = {:encodinganalog => "546"}
	    att.merge!(encodinganalog)
	  when 'custodhist'
	    encodinganalog = {:encodinganalog => "561"}
	    att.merge!(encodinganalog)
	  when 'bibliography'
	    encodinganalog = {:encodinganalog => "581"}
	    att.merge!(encodinganalog)
	  when 'processinfo'
	    encodinganalog = {:encodinganalog => "583"}
	    att.merge!(encodinganalog)
	  when 'accruals'
	    encodinganalog = {:encodinganalog => "584"}
	    att.merge!(encodinganalog)
	  when 'legalstatus'
	    encodinganalog = {:encodinganalog => "355"}
	    att.merge!(encodinganalog)
	  when 'odd'
	    encodinganalog = {:encodinganalog => "500"}
	    att.merge!(encodinganalog)
	  when 'note'
	    encodinganalog = {:encodinganalog => "500"}
	    att.merge!(encodinganalog)
	  when 'materialspec'
	    encodinganalog = {:encodinganalog => "254"}
	    att.merge!(encodinganalog)
	  when 'physdesc'
	    encodinganalog = {:encodinganalog => "300"}
	    att.merge!(encodinganalog)
	  when 'physfacet'
	    encodinganalog = {:encodinganalog => "300"}
	    att.merge!(encodinganalog)
	  when 'physloc'
	    encodinganalog = {:encodinganalog => "300"}
	    att.merge!(encodinganalog)
	  when 'appraisal'
	    encodinganalog = {:encodinganalog => "583"}
	    att.merge!(encodinganalog)
	  when 'bibliography'
	    encodinganalog = {:encodinganalog => "510"}
	    att.merge!(encodinganalog)
      when 'separatedmaterial'
	    encodinganalog = {:encodinganalog => "544"}
	    att.merge!(encodinganalog)
	  else
	    encodinganalog = {}
	    att.merge!(encodinganalog)
	  end
	    

      case note['type']
      when 'dimensions', 'physfacet'
        xml.physdesc(audatt) {
          xml.send(note['type'], att) {
            sanitize_mixed_content( content, xml, fragments, ASpaceExport::Utils.include_p?(note['type'])  )
          }
        }
      else
        xml.send(note['type'], att.merge(audatt)) {
          sanitize_mixed_content(content, xml, fragments,ASpaceExport::Utils.include_p?(note['type']))
        }
      end
    end
  end

  def serialize_note_content(note, xml, fragments)
    return if note["publish"] === false && !@include_unpublished
    audatt = note["publish"] === false ? {:audience => 'internal'} : {}
    content = note["content"]

    #atts = {:id => prefix_id(note['persistent_id']) }.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)
    att ||= {}
	  case note['type']
	  when 'bioghist'
	    encodinganalog = {:encodinganalog => "545"}
	    att.merge!(encodinganalog)
	  when 'scopecontent'
	    encodinganalog = {:encodinganalog => "520"}
	    att.merge!(encodinganalog)
	  when 'abstract'
	    encodinganalog = {:encodinganalog => "520$a"}
	    att.merge!(encodinganalog)
	  when 'accessrestrict'
	    encodinganalog = {:encodinganalog => "506"}
	    att.merge!(encodinganalog)
	  when 'prefercite'
	    encodinganalog = {:encodinganalog => "524"}
	    att.merge!(encodinganalog)
      when 'arrangement'
	    encodinganalog = {:encodinganalog => "351"}
	    att.merge!(encodinganalog)
	  when 'altformavail'
	    encodinganalog = {:encodinganalog => "530"}
	    att.merge!(encodinganalog)
      when 'userestrict'
	    encodinganalog = {:encodinganalog => "540"}
	    att.merge!(encodinganalog)
	  when 'acqinfo'
	    encodinganalog = {:encodinganalog => "541"}
		att.merge!(encodinganalog)
	  when 'relatedmaterial'
	    encodinganalog = {:encodinganalog => "545"}
	    att.merge!(encodinganalog)
	  when 'langmaterial'
	    encodinganalog = {:encodinganalog => "546"}
	    att.merge!(encodinganalog)
	  when 'custodhist'
	    encodinganalog = {:encodinganalog => "561"}
	    att.merge!(encodinganalog)
	  when 'bibliography'
	    encodinganalog = {:encodinganalog => "581"}
	    att.merge!(encodinganalog)
	  when 'processinfo'
	    encodinganalog = {:encodinganalog => "583"}
	    att.merge!(encodinganalog)
	  when 'accruals'
	    encodinganalog = {:encodinganalog => "584"}
	    att.merge!(encodinganalog)
	  when 'legalstatus'
	    encodinganalog = {:encodinganalog => "355"}
	    att.merge!(encodinganalog)
	  when 'odd'
	    encodinganalog = {:encodinganalog => "500"}
	    att.merge!(encodinganalog)
	  when 'note'
	    encodinganalog = {:encodinganalog => "500"}
	    att.merge!(encodinganalog)
	  when 'materialspec'
	    encodinganalog = {:encodinganalog => "254"}
	    att.merge!(encodinganalog)
	  when 'physdesc'
	    encodinganalog = {:encodinganalog => "300"}
	    att.merge!(encodinganalog)
	  when 'physfacet'
	    encodinganalog = {:encodinganalog => "300"}
	    att.merge!(encodinganalog)
	  when 'physloc'
	    encodinganalog = {:encodinganalog => "300"}
	    att.merge!(encodinganalog)
	  when 'appraisal'
	    encodinganalog = {:encodinganalog => "583"}
	    att.merge!(encodinganalog)
	  when 'bibliography'
	    encodinganalog = {:encodinganalog => "510"}
	    att.merge!(encodinganalog)
      when 'separatedmaterial'
	    encodinganalog = {:encodinganalog => "544"}
	    att.merge!(encodinganalog)
	  else
	    encodinganalog = {}
	    att.merge!(encodinganalog)
	  end
	
    head_text = note['label'] ? note['label'] : I18n.t("enumerations._note_types.#{note['type']}", :default => note['type'])
    content, head_text = extract_head_text(content, head_text)
    xml.send(note['type'], att) {
      xml.head { sanitize_mixed_content(head_text, xml, fragments) } unless ASpaceExport::Utils.headless_note?(note['type'], content )
      sanitize_mixed_content(content, xml, fragments, ASpaceExport::Utils.include_p?(note['type']) ) if content
      if note['subnotes']
        serialize_subnotes(note['subnotes'], xml, fragments, ASpaceExport::Utils.include_p?(note['type']))
      end
    }
  end

  def customize_ead_data(custom_text,data)
    custom_text + data
  end

  def upcase_initial_char(string)
    reformat_string = string
    get_match = /(^[a-z])(.*)/.match(string)
    if get_match
      reformat_string = get_match[1].upcase + get_match[2]
    end
    reformat_string
  end
  
  def prettify_missing_enumeration(enumeration)
    #Take the machine readable enumeration codes and convert them to human readable (*only* use when localization values are missing)
    enumeration = enumeration.downcase.tr("_", " ")
    #enumeration = enumeration.titleize

    return enumeration
  end

  def serialize_nondid_notes(data, xml, fragments)
    data.notes.each do |note|
      next if note["publish"] === false && !@include_unpublished
      next if note['internal']
      next if note['type'].nil?
      next unless data.archdesc_note_types.include?(note['type'])
      audatt = note["publish"] === false ? {:audience => 'internal'} : {}
      if note['type'] == 'legalstatus'
        xml.accessrestrict(audatt) {
          serialize_note_content(note, xml, fragments)
        }
      else
        serialize_note_content(note, xml, fragments)
      end
    end
  end


  def serialize_bibliographies(data, xml, fragments)
    data.bibliographies.each do |note|
      next if note["publish"] === false && !@include_unpublished
      content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)
      note_type = note["type"] ? note["type"] : "bibliography"
      head_text = note['label'] ? note['label'] : I18n.t("enumerations._note_types.#{note_type}", :default => note_type )
      audatt = note["publish"] === false ? {:audience => 'internal'} : {}

	  #atts = {:id => prefix_id(note['persistent_id']) }.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)
	  atts ||= {}
	  
      xml.bibliography(atts) {
        xml.head { sanitize_mixed_content(head_text, xml, fragments) }
        sanitize_mixed_content( content, xml, fragments, true)
        note['items'].each do |item|
          xml.bibref { sanitize_mixed_content( item, xml, fragments) }  unless item.empty?
        end
      }
    end
  end


  def serialize_indexes(data, xml, fragments)
    data.indexes.each do |note|
      next if note["publish"] === false && !@include_unpublished
      audatt = note["publish"] === false ? {:audience => 'internal'} : {}
      content = ASpaceExport::Utils.extract_note_text(note, @include_unpublished)
      head_text = nil
      if note['label']
        head_text = note['label']
      elsif note['type']
        head_text = I18n.t("enumerations._note_types.#{note['type']}", :default => note['type'])
      end
	  
	  #atts = {:id => prefix_id(note["persistent_id"]) }.reject{|k,v| v.nil? || v.empty? || v == "null" }.merge(audatt)
	  atts ||= {}
	  
      content, head_text = extract_head_text(content, head_text)
      xml.index(atts) {
        xml.head { sanitize_mixed_content(head_text,xml,fragments ) } unless head_text.nil?
        sanitize_mixed_content(content, xml, fragments, true)
        note['items'].each do |item|
          next unless (node_name = data.index_item_type_map[item['type']])
          xml.indexentry {
            atts = item['reference'] ? {:target => prefix_id( item['reference']) } : {}
            if (val = item['value'])
              xml.send(node_name) {  sanitize_mixed_content(val, xml, fragments )}
            end
            if (val = item['reference_text'])
              xml.ref(atts) {
                sanitize_mixed_content( val, xml, fragments)
              }
            end
          }
        end
      }
    end
  end


  def serialize_eadheader(data, xml, fragments)
    eadheader_atts = {:findaidstatus => data.finding_aid_status,
                      :repositoryencoding => "iso15511",
                      :countryencoding => "iso3166-1",
                      :dateencoding => "iso8601",
                      :langencoding => "iso639-2b"}.reject{|k,v| v.nil? || v.empty? || v == "null"}

    xml.eadheader(eadheader_atts) {

      eadid_atts = {:countrycode => data.repo.country,
              :url => data.ead_location,
              :mainagencycode => data.repo.repo_code,
			  :encodinganalog => "852$a"}.reject{|k,v| v.nil? || v.empty? || v == "null"
			  }
	
      xml.eadid(eadid_atts) {
        xml.text data.ead_id
      }

      xml.filedesc {

        xml.titlestmt {

          titleproper = ""
          titleproper += "#{data.finding_aid_title} " if data.finding_aid_title
          titleproper += "#{data.title}" if ( data.title && titleproper.empty? )
          #titleproper += "<num>#{(0..3).map{|i| data.send("id_#{i}")}.compact.join('.')}</num>"
          #xml.titleproper("type" => "filing") { sanitize_mixed_content(data.finding_aid_filing_title, xml, fragments)} unless data.finding_aid_filing_title.nil?
          xml.titleproper {  sanitize_mixed_content(titleproper, xml, fragments) }
          xml.subtitle {  sanitize_mixed_content(data.finding_aid_subtitle, xml, fragments) } unless data.finding_aid_subtitle.nil?
          xml.author { sanitize_mixed_content(data.finding_aid_author, xml, fragments) }  unless data.finding_aid_author.nil?
          xml.sponsor { sanitize_mixed_content( data.finding_aid_sponsor, xml, fragments) } unless data.finding_aid_sponsor.nil?

        }

        unless data.finding_aid_edition_statement.nil?
          xml.editionstmt {
            sanitize_mixed_content(data.finding_aid_edition_statement, xml, fragments, true )
          }
        end

        xml.publicationstmt {
          xml.publisher { sanitize_mixed_content(data.repo.name,xml, fragments) }

          if data.repo.image_url
            xml.p ( { "id" => "logostmt" } ) {
              xml.extref ({"xlink:href" => data.repo.image_url,
                          "xlink:actuate" => "onLoad",
                          "xlink:show" => "embed",
                          "xlink:type" => "simple"
                          })
                          }
          end
          if (data.finding_aid_date)
            xml.p {
                  val = data.finding_aid_date
                  xml.date {   sanitize_mixed_content( val, xml, fragments) }
                  }
          end

          unless data.addresslines.empty?
            xml.address {
              data.addresslines.each do |line|
                xml.addressline { sanitize_mixed_content( line, xml, fragments) }
              end
              if data.repo.url
                xml.addressline ( "URL: " ) {
                  xml.extptr ( {
                          "xlink:href" => data.repo.url,
                          "xlink:title" => data.repo.url,
                          "xlink:type" => "simple",
                          "xlink:show" => "new"
                          } )
                 }
              end
            }
          end
        }

        if (data.finding_aid_series_statement)
          val = data.finding_aid_series_statement
          xml.seriesstmt {
            sanitize_mixed_content(  val, xml, fragments, true )
          }
        end
        if ( data.finding_aid_note )
            val = data.finding_aid_note
            xml.notestmt { xml.note { sanitize_mixed_content(  val, xml, fragments, true )} }
        end

      }

      xml.profiledesc {
        creation = "This finding aid was produced using ArchivesSpace on <date>#{Time.now}</date>."
        xml.creation {  sanitize_mixed_content( creation, xml, fragments) }

        if (val = data.finding_aid_language)
          xml.langusage (fragments << val)
        end

        if (val = data.descrules)
          xml.descrules { sanitize_mixed_content(val, xml, fragments) }
        end
      }

      if data.revision_statements.length > 0
        xml.revisiondesc {
          data.revision_statements.each do |rs|
              if rs['description'] && rs['description'].strip.start_with?('<')
                xml.text (fragments << rs['description'] )
              else
                xml.change {
                  rev_date = rs['date'] ? rs['date'] : ""
                  xml.date (fragments <<  rev_date )
                  xml.item (fragments << rs['description']) if rs['description']
                }
              end
          end
        }
      end
    }
  end
end