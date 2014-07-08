class CongressionalDocument 
  include Api::Model
  # just using elasticsearch
  publicly :searchable

  basic_fields :id,  :chamber, :committee, :committee_names,
            :committee_id, :congress, :house_event_id, :text_preview,
            :hearing_title, :bill_id, :description, :occurs_at,
            :version_code, :bioguide_id, :published_on, :urls, :type,
			      :witness

  search_fields  :hearing_title, :text

  cite_key :document_id

# add indexes

end