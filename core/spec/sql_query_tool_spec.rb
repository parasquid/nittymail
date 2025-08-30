# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/nittymail/query_tools'
require_relative '../lib/nittymail/db'
require 'sequel'

RSpec.describe NittyMail::QueryTools do
  let(:db) { Sequel.sqlite }

  before do
    # Create test database with sample data (skip vector tables for testing)
    db.create_table :email do
      primary_key :id
      String :address, index: true
      String :mailbox, index: true
      Bignum :uid, index: true, default: 0
      Integer :uidvalidity, index: true, default: 0
      String :message_id, index: true
      DateTime :date, index: true
      String :from, index: true
      String :subject
      Boolean :has_attachments, index: true, default: false
      String :x_gm_labels
      String :x_gm_msgid
      String :x_gm_thrid
      String :flags
      String :encoded
      unique %i[mailbox uid uidvalidity]
      index %i[mailbox uidvalidity]
    end
    
    # Insert test email data
    db[:email].insert(
      id: 1,
      address: 'test@example.com',
      mailbox: 'INBOX',
      uid: 1,
      uidvalidity: 1,
      message_id: '<test1@example.com>',
      date: '2023-01-01 10:00:00',
      from: '["sender@example.com"]',
      subject: 'Test email about merge proposal',
      has_attachments: false,
      encoded: 'Test email body with merge content'
    )
    
    db[:email].insert(
      id: 2,
      address: 'test@example.com',
      mailbox: 'INBOX',
      uid: 2,
      uidvalidity: 1,
      message_id: '<test2@example.com>',
      date: '2023-01-02 11:00:00',
      from: '["another@example.com"]',
      subject: 'Update on project status',
      has_attachments: true,
      encoded: 'Project update with delete old files instruction'
    )
  end

  after do
    db&.disconnect
  end

  describe '#execute_sql_query' do
    context 'valid SELECT queries' do
      it 'executes basic SELECT query' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT COUNT(*) as total FROM email'
        )
        
        expect(result[:query]).to eq('SELECT COUNT(*) as total FROM email LIMIT 1000')
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:total]).to eq(2)
      end

      it 'executes SELECT with WHERE clause' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT * FROM email WHERE subject LIKE '%merge%'"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:subject]).to eq('Test email about merge proposal')
      end

      it 'executes SELECT with custom LIMIT' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT * FROM email LIMIT 1'
        )
        
        expect(result[:query]).to eq('SELECT * FROM email LIMIT 1')
        expect(result[:row_count]).to eq(1)
      end

      it 'auto-adds LIMIT when not specified' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT * FROM email',
          limit: 5
        )
        
        expect(result[:query]).to eq('SELECT * FROM email LIMIT 5')
        expect(result[:row_count]).to eq(2)
      end

      it 'allows searching for emails containing SQL keywords' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT * FROM email WHERE encoded LIKE '%delete%'"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:subject]).to eq('Update on project status')
      end

      it 'supports WITH clauses (CTEs)' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'WITH recent AS (SELECT * FROM email WHERE date > "2023-01-01") SELECT COUNT(*) as count FROM recent'
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:count]).to eq(2)
      end

      it 'handles complex queries with JOINs and GROUP BY' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT mailbox, COUNT(*) as count FROM email GROUP BY mailbox ORDER BY count DESC'
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:mailbox]).to eq('INBOX')
        expect(result[:rows].first[:count]).to eq(2)
      end
    end

    context 'security restrictions' do
      it 'blocks queries not starting with SELECT or WITH' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SHOW TABLES'
        )
        
        expect(result[:error]).to include('Only SELECT queries and WITH expressions')
        expect(result[:example]).to include('SELECT * FROM email')
      end

      it 'blocks DELETE FROM statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT * FROM email; DELETE FROM email WHERE id = 1'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('delete from')
      end

      it 'blocks UPDATE SET statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT id FROM email WHERE id = 1; UPDATE email SET subject = "hacked"'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('update email set')
      end

      it 'blocks INSERT INTO statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'INSERT INTO email (subject) VALUES ("malicious")'
        )
        
        expect(result[:error]).to include('Only SELECT queries and WITH expressions')
      end

      it 'blocks DROP TABLE statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT 1; DROP TABLE email'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('drop table')
      end

      it 'blocks CREATE TABLE statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT 1; CREATE TABLE malicious (id INT)'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('create table')
      end

      it 'blocks ALTER TABLE statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT 1; ALTER TABLE email ADD COLUMN malicious TEXT'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('alter table')
      end

      it 'blocks PRAGMA statements' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT 1; PRAGMA table_info(email)'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('pragma')
      end

      it 'blocks transaction commands' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT 1; BEGIN TRANSACTION; COMMIT'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('begin transaction')
      end

      it 'blocks ATTACH DATABASE commands' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT 1; ATTACH DATABASE "malicious.db" AS mal'
        )
        
        expect(result[:error]).to include('Forbidden SQL operation detected')
        expect(result[:error]).to include('attach database')
      end
    end

    context 'edge cases and error handling' do
      it 'returns error for empty query' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: ''
        )
        
        expect(result[:error]).to eq('SQL query is required')
      end

      it 'returns error for nil query' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: nil
        )
        
        expect(result[:error]).to eq('SQL query is required')
      end

      it 'handles SQL syntax errors gracefully' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT * FROM nonexistent_table'
        )
        
        expect(result[:error]).to include('SQL execution error')
        expect(result[:query]).to eq('SELECT * FROM nonexistent_table LIMIT 1000')
        expect(result[:hint]).to include('Check your SQL syntax')
      end

      it 'handles malformed SQL gracefully' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT FROM WHERE'
        )
        
        expect(result[:error]).to include('SQL execution error')
        expect(result[:hint]).to include('only SELECT queries are allowed')
      end

      it 'preserves encoding safety in results' do
        # Insert email with potentially problematic encoding
        db[:email].insert(
          id: 3,
          address: 'test@example.com',
          mailbox: 'INBOX',
          uid: 3,
          uidvalidity: 1,
          message_id: '<test3@example.com>',
          date: '2023-01-03 12:00:00',
          from: '["test@example.com"]',
          subject: 'Test with special chars: áéíóú',
          has_attachments: false,
          encoded: 'Body with special characters: áéíóú'
        )
        
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT subject FROM email WHERE id = 3"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:subject]).to be_a(String)
      end
    end

    context 'legitimate content searches that should pass' do
      it 'allows searching for "merge" in email content' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT * FROM email WHERE subject LIKE '%merge%' OR encoded LIKE '%merge%'"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:subject]).to include('merge')
      end

      it 'allows searching for "update" in email content' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT * FROM email WHERE subject LIKE '%Update%'"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:subject]).to include('Update')
      end

      it 'allows searching for "delete" in email content' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT * FROM email WHERE encoded LIKE '%delete%'"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:encoded]).to include('delete')
      end

      it 'allows complex searches with multiple keywords' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: "SELECT COUNT(*) as count FROM email WHERE subject LIKE '%merge%' OR subject LIKE '%update%' OR encoded LIKE '%delete%'"
        )
        
        expect(result[:row_count]).to eq(1)
        expect(result[:rows].first[:count]).to eq(2)
      end
    end

    context 'response format validation' do
      it 'returns properly structured response for successful queries' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT COUNT(*) as total FROM email'
        )
        
        expect(result).to have_key(:query)
        expect(result).to have_key(:row_count)
        expect(result).to have_key(:rows)
        expect(result[:rows]).to be_an(Array)
        expect(result[:row_count]).to be_an(Integer)
        expect(result[:query]).to be_a(String)
      end

      it 'returns properly structured error response' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'DELETE FROM email'
        )
        
        expect(result).to have_key(:error)
        expect(result[:error]).to be_a(String)
      end

      it 'symbolizes keys in result rows' do
        result = described_class.execute_sql_query(
          db: db,
          sql_query: 'SELECT id, subject FROM email LIMIT 1'
        )
        
        expect(result[:rows].first.keys).to all(be_a(Symbol))
        expect(result[:rows].first).to have_key(:id)
        expect(result[:rows].first).to have_key(:subject)
      end
    end
  end
end