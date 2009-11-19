require 'bdb'
require 'tuple'
require File.dirname(__FILE__) + '/environment'

class Bdb::Database
  def initialize(name, opts = {})
    @name    = name
    @config  = Bdb::Environment.config.merge(opts)
    @indexes = {}
  end
  attr_reader :name, :indexes

  def config(config = {})
    @config.merge!(config)
  end

  def index_by(field, opts = {})
    raise "index on #{field} already exists" if indexes[field]
    indexes[field] = opts
  end

  def db(index = nil)
    if @db.nil?
      @db = {}
      transaction(false) do
        primary_db = environment.env.db
        primary_db.pagesize = config[:page_size] if config[:page_size]
        primary_db.open(transaction, name, nil, Bdb::Db::BTREE, Bdb::DB_CREATE, 0)
        @db[:primary_key] = primary_db

        indexes.each do |field, opts|
          index_callback = lambda do |db, key, data|
            value = Marshal.load(data)
            index_key = value.kind_of?(Hash) ? value[:field] : value.send(field)
            if opts[:multi_key] and index_key.kind_of?(Array)
              # Index multiple keys. If the key is an array, you must wrap it with an outer array.
              index_key.collect {|k| Tuple.dump(k)}
            elsif index_key
              # Index a single key.
              Tuple.dump(index_key)
            end
          end
          index_db = environment.env.db
          index_db.flags = Bdb::DB_DUPSORT unless opts[:unique]
          index_db.pagesize = config[:page_size] if config[:page_size]
          index_db.open(transaction, "#{name}_by_#{field}", nil, Bdb::Db::BTREE, Bdb::DB_CREATE, 0)
          primary_db.associate(transaction, index_db, Bdb::DB_CREATE, index_callback)
          @db[field] = index_db
        end
      end
    end
    @db[index || :primary_key]
  end

  def close
    return unless @db
    synchronize do
      @db.each {|field, db| db.close(0)}
      @db = nil
    end
  end  

  def count(field, key)
    with_cursor(db(field)) do |cursor|
      k, v = cursor.get(Tuple.dump(key), nil, Bdb::DB_SET)
      k ? cursor.count : 0
    end
  end

  def get(*keys, &block)
    opts  = keys.last.kind_of?(Hash) ? keys.pop : {}
    db    = db(opts[:field])
    set   = ResultSet.new(opts, &block)
    flags = opts[:modify] ? Bdb::DB_RMW : 0
    flags = 0 if environment.disable_transactions?
    
    keys.each do |key|
      key = get_key(key, opts)
      if key == :all
        with_cursor(db) do |cursor|          
          if opts[:reverse]
            k,v  = cursor.get(nil, nil, Bdb::DB_LAST | flags)          # Start at the last item.
            iter = lambda {cursor.get(nil, nil, Bdb::DB_PREV | flags)} # Move backward.
          else
            k,v  = cursor.get(nil, nil, Bdb::DB_FIRST | flags)         # Start at the first item.
            iter = lambda {cursor.get(nil, nil, Bdb::DB_NEXT | flags)} # Move forward.
          end

          while k
            set << unmarshal(v, :tuple => k)
            k,v = iter.call
          end
        end
      elsif key.kind_of?(Range)
        # Fetch a range of keys.
        with_cursor(db) do |cursor|
          first = Tuple.dump(key.first)
          last  = Tuple.dump(key.last)

          # Return false once we pass the end of the range.
          cond = key.exclude_end? ? lambda {|k| k < last} : lambda {|k| k <= last}
          if opts[:reverse]
            iter = lambda {cursor.get(nil, nil, Bdb::DB_PREV | flags)} # Move backward.
            
            # Position the cursor at the end of the range.
            k,v = cursor.get(last, nil, Bdb::DB_SET_RANGE | flags) || cursor.get(nil, nil, Bdb::DB_LAST | flags)
            while k and not cond.call(k)
              k,v = iter.call
            end
            
            cond = lambda {|k| k >= first} # Change the condition to stop when we move past the start.
          else
            k,v  = cursor.get(first, nil, Bdb::DB_SET_RANGE | flags)   # Start at the beginning of the range.
            iter = lambda {cursor.get(nil, nil, Bdb::DB_NEXT | flags)} # Move forward.
          end
          
          while k and cond.call(k)
            set << unmarshal(v, :tuple => k)
            k,v = iter.call
          end
        end
      else
        if (db.flags & Bdb::DB_DUPSORT) == 0
          synchronize do
            # There can only be one item for each key.
            data = db.get(transaction, Tuple.dump(key), nil, flags)
            set << unmarshal(data, :key => key) if data
          end
        else
          # Have to use a cursor because there may be multiple items with each key.
          with_cursor(db) do |cursor|
            k,v = cursor.get(Tuple.dump(key), nil, Bdb::DB_SET | flags)
            while k
              set << unmarshal(v, :tuple => k)
              k,v = cursor.get(nil, nil, Bdb::DB_NEXT_DUP | flags)
            end
          end
        end
      end
    end
    set.results
  rescue ResultSet::LimitReached
    set.results
  end

  def set(key, value, opts = {})
    synchronize do
      key   = Tuple.dump(key)
      value = Marshal.dump(value)
      flags = opts[:create] ? Bdb::DB_NOOVERWRITE : 0
      db.put(transaction, key, value, flags)
    end
  end

  def delete(key)
    synchronize do
      key = Tuple.dump(key)
      db.del(transaction, key, 0)
    end
  end

  # Deletes all records in the database. Beware!
  def truncate!
    synchronize do
      db.truncate(transaction)
    end
  end

  def environment
    @environment ||= Bdb::Environment.new(config[:path], self)
  end

  def transaction(nested = true, &block)
    environment.transaction(nested, &block)
  end
  
  def synchronize(&block)
    environment.synchronize(&block)
  end

  def checkpoint(opts = {})
    environment.synchronize(opts)
  end

private

  def get_key(key, opts)
    if opts[:partial] and not key.kind_of?(Range) and not key == :all
      first = [*key]
      last  = first + [true]
      key   = first..last
    end
    key
  end

  def unmarshal(value, opts = {})
    value = Marshal.load(value)
    value.bdb_locator_key = opts[:tuple] ? Tuple.load(opts[:tuple]) : [*opts[:key]]
    value
  end

  def with_cursor(db)
    synchronize do
      begin
        cursor = db.cursor(transaction, 0)
        yield(cursor)
      ensure
        cursor.close if cursor
      end
    end
  end

  class ResultSet
    class LimitReached < Exception; end

    def initialize(opts, &block)
      @block  = block
      @count  = 0
      @limit  = opts[:limit] || opts[:per_page]
      @limit  = @limit.to_i if @limit
      @offset = opts[:offset] || (opts[:page] ? @limit * (opts[:page] - 1) : 0)
      @offset = @offset.to_i if @offset

      if @group = opts[:group]
        raise 'block not supported with group' if @block     
        @results = {}
      else
        @results = []
      end
    end
    attr_reader :count, :group, :limit, :offset, :results

    def <<(item)
      @count += 1
      return if count <= offset

      raise LimitReached if limit and count > limit + offset

      if group
        key = item.bdb_locator_key
        group_key = group.is_a?(Fixnum) ? key[0,group] : key
        (results[group_key] ||= []) << item
      elsif @block
        @block.call(item)
      else
        results << item
      end
    end
  end
end

class Object
  attr_accessor :bdb_locator_key
end

# Array comparison should try Tuple comparison first.
class Array
  cmp = instance_method(:<=>)

  define_method(:<=>) do |other|
    begin
      Tuple.dump(self) <=> Tuple.dump(other)
    rescue TypeError => e
      cmp.bind(self).call(other)
    end
  end
end
