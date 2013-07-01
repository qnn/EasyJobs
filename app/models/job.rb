class Job < ActiveRecord::Base
  belongs_to :server
  belongs_to :interpreter
  has_many :time_stats
  validates_presence_of :name, :script
end
