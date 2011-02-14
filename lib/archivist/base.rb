# Require sub-module's files
mods = File.join(File.dirname(__FILE__),"base","**","*.rb")
Dir.glob(mods).each do |mod|
  require mod
end

module Archivist
  module Base

    DEFAULT_OPTIONS = {:associate_with_original=>false,:allow_multiple_archives=>false}

    def self.included(base)
      base.extend ClassMethods
    end
    
    module ClassMethods
      def has_archive(options={})
        options = DEFAULT_OPTIONS.merge(options)
        options[:allow_multiple_archives] = true if options[:associate_with_original]
        
        serializations = ""
        self.serialized_attributes.each do |key,value|
          serializations << "serialize(:#{key},#{value.to_s})\n"
        end
        
        has_many_association,belongs_to_association = ""
        if options[:associate_with_original]
          has_many_association = "has_many :archived_#{self.table_name},:class_name=>'#{self.new.class.to_s}::Archive'" 
          belongs_to_association = "belongs_to :#{self.table_name},:class_name=>'#{self.new.class.to_s}'"
        end

        class_eval <<-EOF
          alias_method :delete!, :delete
          
          class << self
            alias_method :delete_all!, :delete_all
          end
          
          def self.archive_indexes
            #{Array(options[:indexes]).collect{|i| i.to_s}.inspect}
          end

          def self.archive_options
            #{options.inspect}
          end
          
          def self.has_archive?
            true
          end
          
          def self.acts_as_archive?
            warn "DEPRECATION WARNING: #acts_as_archive is provided for compatibility with AAA and will be removed soon, please use has_archive?"
            has_archive?
          end

          class Archive < ActiveRecord::Base
            self.record_timestamps = false
            self.table_name = "archived_#{self.table_name}"
            #{serializations}
            #{belongs_to_association}
            include Archivist::ArchiveMethods
          end

          #{has_many_association}
        EOF
        include InstanceMethods
        extend ClassExtensions
        include DB
      end

      def acts_as_archive(options={})
        has_archive(options)
      end
    end
    
    module InstanceMethods #these defs can't happen untill after we've aliased their respective originals
      def delete
        self.class.copy_to_archive({:id=>self.id}) unless new_record?
        @destroyed = true
        freeze
      end
      
      def destroy
        _run_destroy_callbacks do
          self.delete
        end
      end
      
      def destroy!
        transaction do
          _run_destroy_callbacks do
            self.delete!
          end
        end
      end
    end

    module ClassExtensions #these can't get included in the class def untill after all aliases are done
      def copy_to_archive(conditions,delete=true)
        where = sanitize_sql(conditions)
        found = self.where(where)
        
        found.each do |m|
          self.transaction do # I would hate for something to happen in the middle of all of this
            attrs = m.attributes.merge(:deleted_at=>DateTime.now)
            
            archived = self::Archive.new
            if self::Archive.where(:id=>m.id).empty? #create a new one if necessary, else update
              archived.id = m.id
              archived.attributes = attrs.reject{|k,v| k==:id}
            else
              archived = self::Archive.where(:id=>m.id).first
              archived.update_attributes(attrs)
            end
            yield(archived) if block_given?
            archived.save
            m.destroy! if delete
          end
        end
      end
      
      def copy_from_archive(conditions,delete=true)
        where = sanitize_sql(conditions)
        where = where.gsub("#{table_name}","archived_#{table_name}") unless where.nil? || where =~ /archived/
        unless where == ""
          found = self::Archive.where(where)
        else
          found = self::Archive.all
        end

        found.each do |m|
          self.transaction do
            my_attribute_names = self.new.attribute_names
            #this should be Hash.select but 1.8.7 returns an array from select but a hash from reject... dumb
            attrs = m.attributes.reject{|k,v| !my_attribute_names.include?(k.to_s)} 

            if self.where(:id=>m.id).empty?
              new_m = self.create(attrs)
              connection.execute(%Q{UPDATE #{table_name} 
                                    SET #{self.primary_key} = #{m.id} 
                                    WHERE #{self.primary_key} = #{new_m.id}
                                   })
            else
              self.where(:id=>m.id).first.update_attributes(attrs)
            end
            m.destroy if delete  
          end
        end
      end

      def delete_all(conditions=nil)
        copy_to_archive(conditions)
      end

      def restore_all(conditions=nil)
        copy_from_archive(conditions)
      end
    end
  end
end
