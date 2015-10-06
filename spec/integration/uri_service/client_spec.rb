require 'spec_helper'
require 'yaml'
require 'uri_service/client'

describe UriService::Client, type: :integration do
  
  let(:uri_service_sqlite_config) { YAML.load(fixture('uri_service_test_config.yml'))['sqlite'] }
  let(:uri_service_fake_mysql2_config) { YAML.load(fixture('uri_service_test_config.yml'))['mysql2'] }
  
  # Clear all terms and vocabularies in database and solr before each example
  before :example do
    # Clear DB
    UriService.required_tables.each do |table|
      UriService.client.db[table].delete
    end
    # Clear Solr
    UriService.client.rsolr_pool.with do |rsolr|
      rsolr.delete_by_query('*:*')
      rsolr.commit
    end
  end

  describe "#test_connection" do
    
    it "can test a successful connection without raising any errors" do
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.not_to raise_error
    end
    
    it "raises an exception if no local_uri_base config is supplied" do
      uri_service_sqlite_config['local_uri_base'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['local_uri_base'] to initialize method.")
    end
    
    it "raises an exception if no database config is supplied" do
      uri_service_sqlite_config['database'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['database'] to initialize method.")
    end
    
    it "raises an exception if no solr config is supplied" do
      uri_service_sqlite_config['solr'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['solr'] to initialize method.")
    end
    
    it "raises an exception when the database connection is unavailable" do
      expect{ UriService::Client.new(uri_service_fake_mysql2_config).test_connection }.to raise_error(Sequel::DatabaseConnectionError)
    end
    
    it "raises an exception when the database connection is unavailable" do
      uri_service_sqlite_config['solr']['url'] = 'http://localhost:10101/fake/solr'
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error(Errno::ECONNREFUSED)
    end
    
  end
  
  describe "vocabulary create/update/delete/etc. methods" do
    describe "#create_vocabulary" do
      it "successfully creates a new vocabulary" do
        new_vocabulary_string_key = 'create_example'
        new_vocabulary_display_label = 'Create Example'
        expect(UriService.client.db[:vocabularies].where(string_key: new_vocabulary_string_key).count).to eq(0)
        UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label)
        expect(UriService.client.db[:vocabularies].where(string_key: new_vocabulary_string_key).count).to eq(1)
      end
      it "raises an exception when trying to create more than one vocabulary with the same string key" do
        new_vocabulary_string_key = 'another_create_example'
        new_vocabulary_display_label = 'Another Create Example'
        UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label) # First creation
        expect {
          UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label) # Duplicate creation
        }.to raise_error(UriService::ExistingVocabularyStringKeyError)
      end
      it "rejects invalid string keys" do
        ['all', 'invalid key', '_invalid', 'Invalid', '???invalid'].each_with_index do |invalid_key, index|
          expect {
            UriService.client.create_vocabulary(invalid_key, 'Some Label') # First creation
          }.to raise_error(UriService::InvalidVocabularyStringKeyError)
        end
      end
    end
    
    describe "#find_vocabulary" do
      it "returns nil when a vocabulary is not found" do
        expect(UriService.client.find_vocabulary('random12345nonexistent12345zzzz')).to be_nil
      end
      
      it "successfully finds a newly created vocabulary" do
        new_vocabulary_string_key = 'vocabulary_to_find'
        new_vocabulary_display_label = 'Vocabulary to Find'
        expect(UriService.client.find_vocabulary(new_vocabulary_string_key)).to be_nil
        UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label)
        found_vocabulary = UriService.client.find_vocabulary(new_vocabulary_string_key)
        expect(found_vocabulary[:string_key]).to eq(new_vocabulary_string_key)
        expect(found_vocabulary[:display_label]).to eq(new_vocabulary_display_label)
      end
    end
    
    describe "#delete_vocabulary" do
      it "successfully deletes a newly created vocabulary" do
        vocabulary_to_delete_string_key = 'vocabulary_to_delete'
        vocabulary_to_delete_display_label = 'Vocabulary to Delete'
        expect(UriService.client.find_vocabulary(vocabulary_to_delete_string_key)).to be_nil
        UriService.client.create_vocabulary(vocabulary_to_delete_string_key, vocabulary_to_delete_display_label)
        expect(UriService.client.find_vocabulary(vocabulary_to_delete_string_key)).not_to be_nil
        UriService.client.delete_vocabulary(vocabulary_to_delete_string_key)
        expect(UriService.client.find_vocabulary(vocabulary_to_delete_string_key)).to be_nil
      end
    end
    
    describe "#update_vocabulary" do
      it "successfully updates an existing vocabulary" do
        vocabulary_string_key = 'vocabulary_to_find'
        vocabulary_display_label = 'Vocabulary to Find'
        UriService.client.create_vocabulary(vocabulary_string_key, vocabulary_display_label)
        found_vocabulary = UriService.client.find_vocabulary(vocabulary_string_key)
        expect(found_vocabulary[:string_key]).to eq(vocabulary_string_key)
        expect(found_vocabulary[:display_label]).to eq(vocabulary_display_label)
        UriService.client.update_vocabulary(vocabulary_string_key, 'New Label')
        found_vocabulary = UriService.client.find_vocabulary(vocabulary_string_key)
        expect(found_vocabulary[:string_key]).to eq(vocabulary_string_key)
        expect(found_vocabulary[:display_label]).to eq('New Label')
      end
      it "raises an exception when trying to update a vocabulary that has not been created" do
        expect {
          UriService.client.update_vocabulary('vocabulary_does_not_exist', 'New Label')
        }.to raise_error(UriService::NonExistentVocabularyError)
      end
    end
  end
  
  describe "term create/update/delete/etc. methods" do
    
    context "term creation" do
      describe "#create_term_impl" do
        it "rejects invalid URIs" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          expect {
            # Invalid URI structure
            UriService.client.create_term_impl(vocabulary_string_key, 'zzz', "Hey, that's not a URI!", {}, false)
          }.to raise_error(UriService::InvalidUriError)
          expect {
            # URL without protocol
            UriService.client.create_term_impl(vocabulary_string_key, 'zzz', "something.example.com", {}, false)
          }.to raise_error(UriService::InvalidUriError)
        end
        it "rejects invalid additional_fields keys (which can only contain lower case letters, numbers and underscores, but cannot start with an underscore)" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          ['invalid key', '_invalid', 'Invalid', '???invalid'].each_with_index do |invalid_key, index|
            expect {
              UriService.client.create_term_impl(vocabulary_string_key, 'zzz', "http://id.loc.gov/something/cool", {invalid_key => 'cool value'}, false)
            }.to raise_error(UriService::InvalidAdditionalFieldKeyError)
          end
        end
        it "raises an exception when trying to create a term in a vocabulary that has not been created" do
          vocabulary_string_key = 'nonexistent'
          expect {
            UriService.client.create_term_impl(vocabulary_string_key, 'zzz', 'http://id.library.columbia.edu/term/1234567', {}, false)
          }.to raise_error(UriService::NonExistentVocabularyError)
        end
        it "raises an exception when supplying an additional field that is a reserved key" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          expect {
            UriService.client.create_term_impl(vocabulary_string_key, 'zzz', 'http://id.library.columbia.edu/term/1234567', {'value' => '12345'}, false)
          }.to raise_error(UriService::InvalidAdditionalFieldKeyError)
        end
        it "raises an exception when adding more than one term with the same uri" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term_impl(vocabulary_string_key, 'Value 1', 'http://id.library.columbia.edu/term/1234567', {}, false)
          expect {
            UriService.client.create_term_impl(vocabulary_string_key, 'Value 2', 'http://id.library.columbia.edu/term/1234567', {}, false)
          }.to raise_error(UriService::ExistingUriError)
        end
        it "successfully creates a uri entry in both the database and solr" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          expect(UriService.client.db[UriService::TERMS].where(uri: uri).count).to eq(0)
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term_impl(vocabulary_string_key, 'aaa', uri, {}, false)
          expect(UriService.client.db[UriService::TERMS].where(uri: uri).count).to eq(1)
          
          UriService.client.rsolr_pool.with do |rsolr|
            response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
            expect(response['response']['numFound']).to eq(1)
          end
        end
      end
      
      describe "#create_term" do
        it "delegates work appropriately to the create_term_impl method, thereby creating a new term" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          value = 'What a great value'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, value, uri)
          expect(UriService.client.find_term_by_uri(uri)).not_to be_nil
        end
        it "sets the is_local value to false" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          value = 'What a great value'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, value, uri)
          expect(UriService.client.find_term_by_uri(uri)['is_local']).to eq(false)
        end
      end
      
      describe "#create_local_term" do
        it "creates a new, valid URI for the local term (by not throwing an invalid URI error)" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          expect {
            UriService.client.create_local_term(vocabulary_string_key, 'Good old fashioned value')
          }.not_to raise_error
        end
        it "delegates work appropriately to the create_term_impl method, thereby creating a new term" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_local_term(vocabulary_string_key, 'Cool local value')
          expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Cool local value').length).to eq(1)
        end
        it "sets the is_local value to true" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_local_term(vocabulary_string_key, 'Nice term')
          expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Nice term')[0]['is_local']).to eq(true)
        end
      end
      
    end
    
    describe "#find_term_by_uri" do
      it "can find a newly created uri that includes custom additional fields" do
        vocabulary_string_key = 'names'
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(vocabulary_string_key, value, uri, {'custom_field' => 'custom value'})
        expect(UriService.client.find_term_by_uri(uri)).to eq({
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'is_local' => false,
          'custom_field' => 'custom value'
        })
      end
      it "returns nil for a term uri doesn't exist" do
        expect(UriService.client.find_term_by_uri('http://fake.url.here/really/does/not/exist')).to eq(nil)
      end
    end
    
    describe "#create_term_solr_doc" do
      it "converts as expected" do
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        is_local = false
        vocabulary_string_key = 'some_vocabulary'
        additional_fields = {
          'field1' => 'string value',
          'field2' => 1,
          'field3' => true,
          'field4' => ['val1', 'val2'],
          'field5' => [1, 2, 3, 4, 5]
        }
        
        expected_solr_doc = {
          'uri' => 'http://id.library.columbia.edu/term/1234567',
          'value' => 'What a great value',
          'is_local' => false,
          'vocabulary_string_key' => 'some_vocabulary',
          'field1_ssi' => 'string value',
          'field2_isi' => 1,
          'field3_bsi' => true,
          'field4_ssim' => ['val1', 'val2'],
          'field5_isim' => [1, 2, 3, 4, 5]
        }
        
        expect(UriService.client.create_term_solr_doc(
          vocabulary_string_key, value, uri, additional_fields, is_local
        )).to eq(expected_solr_doc)
      end
    end
    
    describe "#send_term_to_solr" do
      it "correctly creates/updates a document in solr" do
        vocabulary_string_key = 'names'
        value = 'Grrrrreat name!'
        uri = 'http://id.loc.gov/123'
        additional_fields = {'field1' => 1, 'field2' => ['aaa', 'bbb', 'ccc']}
        is_local = false
        
        expected1 = {
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'is_local' => is_local,
          'field1_isi' => additional_fields['field1'],
          'field2_ssim' => additional_fields['field2']
        }
        
        expected2 = {
          'uri' => uri,
          'value' => 'Even grrrreater value!',
          'vocabulary_string_key' => vocabulary_string_key,
          'is_local' => is_local,
          'field1_isi' => additional_fields['field1'],
          'field2_ssim' => additional_fields['field2']
        }
        
        UriService.client.send_term_to_solr(vocabulary_string_key, value, uri, additional_fields, is_local)
        UriService.client.rsolr_pool.with do |rsolr|
          response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
          doc = response['response']['docs'][0]
          expect(doc.except('score', 'timestamp', '_version')).to eq(expected1)
        end
        UriService.client.send_term_to_solr(vocabulary_string_key, 'Even grrrreater value!', uri, additional_fields, is_local)
        UriService.client.rsolr_pool.with do |rsolr|
          response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
          doc = response['response']['docs'][0]
          expect(doc.except('score', 'timestamp', '_version')).to eq(expected2)
        end
      end
    end
    
    describe "#find_terms_by_query" do
      it "can find a newly created value when various partial and complete queries are given (partial must be > 3 chars)" do
        vocabulary_string_key = 'names'
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(vocabulary_string_key, value, uri)
        
        expected_search_results = [{
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'is_local' => false
        }]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'z')).to eq([]) # Letter not present in term returns no results
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'W')).to eq([]) # < 3 char string returns no results
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Wh')).to eq([]) # < 3 char string returns no results
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Wha')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What ')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a ')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a g')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a gr')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a gre')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a grea')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great ')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great v')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great va')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great val')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great valu')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great value')).to eq(expected_search_results)
      end
      
      it "sorts exact matches first" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(vocabulary_string_key, 'Cat', 'http://id.loc.gov/fake/111')
        UriService.client.create_term(vocabulary_string_key, 'Catastrophe', 'http://id.loc.gov/fake/222')
        UriService.client.create_term(vocabulary_string_key, 'Catastrophic', 'http://id.loc.gov/fake/333')
        
        expected_search_results = [
          { 'uri' => 'http://id.loc.gov/fake/111', 'value' => 'Cat', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false },
          { 'uri' => 'http://id.loc.gov/fake/222', 'value' => 'Catastrophe', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false },
          { 'uri' => 'http://id.loc.gov/fake/333', 'value' => 'Catastrophic', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false },
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Cat')).to eq(expected_search_results)
      end
      
      it "sorts full word matches first when present, even if there are other words in the term and it would otherwise sort later alphabetically" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(vocabulary_string_key, 'A Catastrophe', 'http://id.loc.gov/fake/111')
        UriService.client.create_term(vocabulary_string_key, 'Not Catastrophic', 'http://id.loc.gov/fake/222')
        UriService.client.create_term(vocabulary_string_key, 'The Cat', 'http://id.loc.gov/fake/333')
        
        expected_search_results = [
          { 'uri' => 'http://id.loc.gov/fake/333', 'value' => 'The Cat', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false },
          { 'uri' => 'http://id.loc.gov/fake/111', 'value' => 'A Catastrophe', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false },
          { 'uri' => 'http://id.loc.gov/fake/222', 'value' => 'Not Catastrophic', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false },
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Cat')).to eq(expected_search_results)
      end
      
      it "sorts equally relevant results alphabetically" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(vocabulary_string_key, 'Steve Kobs', 'http://id.loc.gov/fake/222')
        UriService.client.create_term(vocabulary_string_key, 'Steve Jobs', 'http://id.loc.gov/fake/111')
        UriService.client.create_term(vocabulary_string_key, 'Steve Lobs', 'http://id.loc.gov/fake/333')
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/111',
            'value' => 'Steve Jobs',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          },
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'Steve Kobs',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          },
          {
            'uri' => 'http://id.loc.gov/fake/333',
            'value' => 'Steve Lobs',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Steve')).to eq(expected_search_results)
      end
      
      it "returns results for mid-word partial word queries" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(vocabulary_string_key, 'Supermanners', 'http://id.loc.gov/fake/111')
        UriService.client.create_term(vocabulary_string_key, 'Batmanners', 'http://id.loc.gov/fake/222')
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'Batmanners',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          },
          {
            'uri' => 'http://id.loc.gov/fake/111',
            'value' => 'Supermanners',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'man')).to eq(expected_search_results)
      end
      
      it "doesn't return results that do not include the query" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(vocabulary_string_key, 'Supermanners', 'http://id.loc.gov/fake/111')
        UriService.client.create_term(vocabulary_string_key, 'Batmanners', 'http://id.loc.gov/fake/222')
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'Batmanners',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'bat')).to eq(expected_search_results)
      end
      
      it "performs a case insensitive search" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(vocabulary_string_key, 'BATMANNERS', 'http://id.loc.gov/fake/222')
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'BATMANNERS',
            'vocabulary_string_key' => vocabulary_string_key,
            'is_local' => false
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'bAtMaNnErS')).to eq(expected_search_results)
      end
      
      it "returns all terms when the supplied query is an empty string" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(vocabulary_string_key, 'Val 1', 'http://id.loc.gov/fake/term1')
        UriService.client.create_term(vocabulary_string_key, 'Val 2', 'http://id.loc.gov/fake/term2')
        UriService.client.create_term(vocabulary_string_key, 'Val 3', 'http://id.loc.gov/fake/term3')
        
        expected_search_results = [
          {'uri' => 'http://id.loc.gov/fake/term1', 'value' => 'Val 1', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/term2', 'value' => 'Val 2', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/term3', 'value' => 'Val 3', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false}
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, '')).to eq(expected_search_results)
      end
      
      it "can page through results using the limit and start params, proving that the limit and start params work properly" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        10.times do |i|
          UriService.client.create_term(vocabulary_string_key, "Name #{i}", "http://id.loc.gov/fake/#{i}")
        end
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, '', 4, 0)).to eq([
          {'uri' => 'http://id.loc.gov/fake/0', 'value' => 'Name 0', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/1', 'value' => 'Name 1', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/2', 'value' => 'Name 2', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/3', 'value' => 'Name 3', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
        ])
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, '', 4, 4)).to eq([
          {'uri' => 'http://id.loc.gov/fake/4', 'value' => 'Name 4', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/5', 'value' => 'Name 5', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/6', 'value' => 'Name 6', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/7', 'value' => 'Name 7', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
        ])
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, '', 4, 8)).to eq([
          {'uri' => 'http://id.loc.gov/fake/8', 'value' => 'Name 8', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
          {'uri' => 'http://id.loc.gov/fake/9', 'value' => 'Name 9', 'vocabulary_string_key' => vocabulary_string_key, 'is_local' => false},
        ])
        
      end
      
    end
    
    describe "#delete_term" do
      it "can delete a term" do
        vocabulary_string_key = 'names'
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(vocabulary_string_key, value, uri)
        expect(UriService.client.find_term_by_uri(uri)).not_to eq(nil)
        UriService.client.delete_term(uri)
        expect(UriService.client.find_term_by_uri(uri)).to eq(nil)
      end
    end
    
    context "term update methods" do
      
      describe "#update_term" do
        it "properly updates both the database and solr" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, 'My term', uri, {})
          expect(UriService.client.db[UriService::TERMS].where(uri: uri).count).to eq(1)
          UriService.client.rsolr_pool.with do |rsolr|
            response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
            expect(response['response']['numFound']).to eq(1)
          end
          
          new_value = 'updated value'
          new_additional_fields = {'updated' => true, 'cool' => 'very'}
          UriService.client.update_term(uri, {value: new_value, additional_fields: new_additional_fields}, false)
          
          db_row = UriService.client.db[UriService::TERMS].where(uri: uri).first
          doc = nil
          UriService.client.rsolr_pool.with do |rsolr|
            response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
            doc = response['response']['docs'].first
          end
          
          expect(db_row.except(:id)).to eq({
            :vocabulary_string_key => 'names',
            :value => new_value,
            :uri => "http://id.library.columbia.edu/term/1234567",
            :uri_hash => "7dbe84657ed648d1748cb03d862cd4a45e590037bc4c2fcdbd04062ef4be226f",
            :is_local => false,
            :additional_fields => JSON.generate(new_additional_fields)
          })
          expect(doc.except('timestamp', '_version_', 'score')).to eq({
            "vocabulary_string_key" => "names",
            "value" => "updated value",
            "uri" => "http://id.library.columbia.edu/term/1234567",
            "is_local" => false,
            "updated_bsi" => true,
            "cool_ssi" => "very"
          })
        end
        it "raises an exception when trying to update a term that does not exist" do
          expect {
            UriService.client.update_term('http://this.does.not.exist/really/does/not', {value: 'New Value'})
          }.to raise_error(UriService::NonExistentUriError)
        end
        it "can update the value and additional_fields for an existing term" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, 'Original Value', uri)
          expect(UriService.client.find_term_by_uri(uri)['value']).to eq('Original Value')
          UriService.client.update_term(uri, {value: 'New Value', additional_fields: {'new_field' => 'new field value'}})
          term = UriService.client.find_term_by_uri(uri)
          expect(term['value']).to eq('New Value')
          expect(term['new_field']).to eq('new field value')
        end
        it "rejects invalid additional_fields keys (which can only contain lower case letters, numbers and underscores, but cannot start with an underscore)" do
          vocabulary_string_key = 'names'
          uri = "http://id.library.columbia.edu/term/111"
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, 'Value', uri, {'valid_key' => 'cool value'})
          ['invalid key', '_invalid', 'Invalid', '???invalid'].each_with_index do |invalid_key, index|
            expect {
              UriService.client.update_term(uri, {additional_fields: {invalid_key => 'some value'}})
            }.to raise_error(UriService::InvalidAdditionalFieldKeyError)
          end
        end
        it "raises an exception when trying to update a term that does not exist" do
          expect {
            UriService.client.update_term('http://this.does.not.exist/really/does/not', {additional_fields: {'something' => 'here'}})
          }.to raise_error(UriService::NonExistentUriError)
        end
        it "merges supplied additional fields for a regular term when merge param is not supplied (because merge defaults to true)" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, 'Original Value', uri, {'some_key' => 'some val'})
          expect(UriService.client.find_term_by_uri(uri)['some_key']).to eq('some val')
          UriService.client.update_term(uri, {additional_fields: {'another_key' => 'another val'}})
          term = UriService.client.find_term_by_uri(uri)
          expect(term['some_key']).to eq('some val')
          expect(term['another_key']).to eq('another val')
        end
        it "can replace all of the additional fields for a regular term when merge param equals false" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(vocabulary_string_key, 'Original Value', uri, {'some_key' => 'some val'})
          expect(UriService.client.find_term_by_uri(uri)['some_key']).to eq('some val')
          UriService.client.update_term(uri, {additional_fields: {'another_key' => 'another val'}}, false)
          term = UriService.client.find_term_by_uri(uri)
          expect(term['some_key']).to be_nil
          expect(term['another_key']).to eq('another val')
        end
      end
    end
  end
  
  describe "::get_solr_suffix_for_object" do
    it "creates the expected suffixes for supported object types" do
      expect(UriService::Client::get_solr_suffix_for_object( 'string value'   )).to eq('_ssi')
      expect(UriService::Client::get_solr_suffix_for_object( 1                )).to eq('_isi')
      expect(UriService::Client::get_solr_suffix_for_object( true             )).to eq('_bsi')
      expect(UriService::Client::get_solr_suffix_for_object( ['val1', 'val2'] )).to eq('_ssim')
      expect(UriService::Client::get_solr_suffix_for_object( [1, 2, 3, 4, 5]  )).to eq('_isim')
    end
  
    it "raises an exception for unsupported object types" do
      expect{ UriService::Client::get_solr_suffix_for_object(Struct.new(:something)) }.to raise_error(UriService::UnsupportedObjectTypeError)
    end
  end

end
