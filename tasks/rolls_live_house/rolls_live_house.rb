require 'nokogiri'
require 'open-uri'

class RollsLiveHouse
  
  def self.run(options = {})
    year = Time.now.year
    
    count = 0
    missing_ids = []
    bad_votes = []
    
    legislators = {}
    Legislator.only(Utils.voter_fields).all.each do |legislator|
      legislators[legislator.bioguide_id] = legislator
    end
    
    begin
      last_number = latest_known_roll year
    rescue Timeout::Error
      Report.warning self, "Timeout error on fetching the listing page, can't go on."
      return
    end
    
    current_number = latest_new_roll year
    
    if last_number == current_number
      Report.success self, "No new rolls for the House for #{year}.", :current_number => current_number
      return
    end
    
    if last_number > current_number
      Report.failure self, "Something is wrong, our archive is ahead of the live roll number.", :last_number => last_number, :current_number => current_number
      return
    end
    
    # get each new roll
    (last_number + 1).upto(current_number) do |number|
      url = "http://clerk.house.gov/evs/#{year}/roll#{zero_prefix number}.xml"
      
      doc = nil
      begin
        doc = Nokogiri::XML open(url)
      rescue Timeout::Error
        doc = nil
      end
      
      if doc
        roll_id = "h#{number}-#{year}"
        session = doc.at(:congress).inner_text.to_i
        bill_id = bill_id_for doc, session
        voter_ids, voters = votes_for doc, legislators, missing_ids
        question = doc.at("vote-question").inner_text
        
        vote = Vote.new :roll_id => roll_id
        vote.attributes = {
          :vote_type => "other",
          :how => "roll",
          :chamber => "house",
          :year => year,
          :number => number,
          
          :session => session,
          
          :roll_type => question,
          :question => question,
          :result => doc.at("vote-result").inner_text,
          
          :required => required_for(doc),
          
          # :voted_at => Utils.govtrack_time_for(doc.root['datetime']),
          :voter_ids => voter_ids,
          :voters => voters,
          # :vote_breakdown => vote_breakdown,
        }
        
        if bill_id
          if bill = bill_for(bill_id)
            vote.attributes = {
              :bill_id => bill_id,
              :bill => bill_for(bill_id)
            }
          else
            Report.warning self, "Found bill_id #{bill_id} on House roll no. #{number}, which isn't in the database."
          end
        end
        
        if vote.save
          count += 1
          puts "[#{roll_id}] Saved successfully"
        else
          bad_votes << {:attributes => vote.attributes, :error_messages => vote.errors.full_messages}
          puts "[#{roll_id}] Error saving, will file report"
        end
        
      else
        Report.warning self, "Timeout error on fetching House roll #{number}, skipping and going onto the next one."
      end
    end
    
    if bad_votes.any?
      Report.failure self, "Failed to save #{bad_votes.size} roll calls. Attached the last failed roll's attributes and error messages.", bad_rolls.last
    end
    
    if missing_ids.any?
      missing_ids = missing_ids.uniq
      Report.warning self, "Found #{missing_ids.size} missing Bioguide IDs, attached. Vote counts on roll calls may be inaccurate until these are fixed.", {:missing_ids => missing_ids}
    end
    
    Report.success self, "Fetched #{count} new live roll calls from the House Clerk website."
  end
  
  # latest House roll number that we have information about in our database for a given year
  def self.latest_known_roll(year)
    latest_roll = Vote.where(:how => "roll", :chamber => "house", :year => 2010).only([:number]).order_by([[:number, :desc]]).first
    latest_roll ? latest_roll.number : nil
  end
  
  # latest roll number on the House Clerk's listing of latest votes
  def self.latest_new_roll(year)
    url = "http://clerk.house.gov/evs/#{year}/index.asp"
    doc = Nokogiri::HTML open(url)
    element = doc.css "tr td a"
    if element and element.text.present?
      number = element.text.to_i
      if number > 0
        number
      else
        nil
      end
    else
      nil
    end
  end
  
  def self.bill_for(bill_id)
    bill = Bill.where(:bill_id => bill_id).only(bill_fields).first
    
    if bill
      attributes = bill.attributes
      allowed_keys = bill_fields.map {|f| f.to_s}
      attributes.keys.each {|key| attributes.delete key unless allowed_keys.include?(key)}
      attributes
    else
      nil
    end
  end
  
  def self.bill_fields
    Bill.basic_fields
  end
  
  def self.required_for(doc)
    if doc.at("vote-type").inner_text =~ /^2\/3/i
      "2/3"
    else
      "1/2"
    end
  end
  
  def self.vote_mapping
    {
      "Aye" => "Yea",
      "No" => "Nay"
    }
  end
  
  def self.votes_for(doc, legislators, missing_ids)
    voter_ids = {}
    voters = {}
    
    doc.search("//vote-data/recorded-vote").each do |elem|
      vote = (elem / 'vote').text
      vote = vote_mapping[vote] || vote # check to see if it should be standardized
      
      bioguide_id = (elem / 'legislator').first['name-id']
      voter = voter_for bioguide_id, legislators
      
      if voter
        bioguide_id = voter[:bioguide_id]
        voter_ids[bioguide_id] = vote
        voters[bioguide_id] = {:vote => vote, :voter => voter}
      else
        if bioguide_id.to_i == 0
          missing_ids << [bioguide_id, filename]
        else
          missing_ids << bioguide_id
        end
      end
    end
    
    [voter_ids, voters]
  end
  
  def self.voter_for(bioguide_id, legislators)
    legislator = legislators[bioguide_id]
    
    if legislator
      attributes = legislator.attributes
      allowed_keys = Utils.voter_fields.map {|f| f.to_s}
      attributes.keys.each {|key| attributes.delete key unless allowed_keys.include?(key)}
      attributes
    else
      nil
    end
  end
  
  def self.bill_id_for(doc, session)
    elem = doc.at 'legis-num'
    if elem
      elem.text.strip.gsub(' ', '').downcase + "-#{session}"
    else
      nil
    end
  end
  
  def self.zero_prefix(number)
    if number < 10
      "00#{number}"
    elsif number < 100
      "0#{number}"
    else
      number
    end
  end
  
end