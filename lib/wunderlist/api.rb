# (Inofficial) Wunderlist API Bindings
# vim: sw=2 ts=2 ai et
#
# Copyright (c) 2011 Fritz Grimpen
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require "net/http"
require "digest/md5"
require "json"
require "nokogiri"
require "date"

require "wunderlist/list"
require "wunderlist/task"

module Wunderlist
  ##
  # The API class provides access to the Wunderlist API over HTTP.
  class API
    ##
    # Domain of the Wunderlist API
    attr_reader :domain
    
    ##
    # Path of the Wunderlist API
    attr_reader :path
    
    ##
    # Your email address from login
    attr_reader :email
    
    ##
    # Wunderlist Session ID
    attr_reader :session

    def initialize(domain = "www.wunderlist.com", path = "/")
      @domain = domain
      @path = path
      @http = Net::HTTP.new(@domain)
      @logged_in = false
    end

    ##
    # Request new session and connects it with your login credentials
    def login(email, password)
      get_session if @session == nil
      return true if @logged_in
      @email = email

      req = prepare_request(Net::HTTP::Post.new "#{@path}/ajax/user")
      req.set_form_data({ "email" => @email, "password" => Digest::MD5.hexdigest(password) })
      res = JSON.parse(@http.request(req).body)

      @logged_in = true if res["code"] == 200
      @logged_in
    end

    ##
    # Login with a session ID without login credentials
    def login_by_session(sessid)
      return if @logged_in
      @logged_in = true
      @session = sessid
    end

    ##
    # Delete internal list caching
    def flush
      @lists = nil
    end

    ##
    # Return all lists
    def lists
      @lists = load_lists if @lists == nil
      @lists
    end

    ##
    # Get INBOX list
    def inbox
      lists.values.detect { |list| list.inbox }
    end

    ##
    # Load and parse tasks from Wunderlist API
    def tasks(list)
      list_obj = list.is_a?(Wunderlist::List) ? list : lists[list]
      list = list.id if list.is_a? Wunderlist::List

      request = prepare_request(Net::HTTP::Get.new "#{@path}/ajax/lists/id/#{list}")
      response = @http.request request
      result = []

      Nokogiri::HTML(JSON.parse(response.body)["data"]).css("li.more").each do |html_task|
        task = Wunderlist::Task.new
        task.id = html_task.attributes["id"].value.to_i
        task.name = html_task.css("span.description").first.content
        task.important = html_task.css("span.fav").empty? ? false : true
        task.done = html_task.attributes["class"].value.split(" ").include?("done")
        html_timestamp = html_task.css("span.timestamp")
        task.date = Time.at(html_timestamp.first.attributes["rel"].
        value.to_i).to_date unless html_timestamp.empty?
        task.note = html_task.css('span.note').first.content
        task.api = self
        task.list = list_obj

        result << task
      end

      result
    end

    ##
    # Create new empty List
    def create_list(name)
      Wunderlist::List.new(name, false, self).save
    end

    ##
    # Save List or Task
    def save(obj)
      if obj.is_a? Wunderlist::List
        return save_list obj
      elsif obj.is_a? Wunderlist::Task
        return save_task obj
      end
    end

    ##
    # Destroy List or Task
    def destroy(obj)
      if obj.is_a? Wunderlist::List
        return destroy_list obj
      elsif obj.is_a? Wunderlist::Task
        return destroy_task obj
      end
    end

    protected
    def destroy_list(obj)
      json_data = { "id" => obj.id, "deleted" => 1 }
      request = prepare_request(Net::HTTP::Post.new "#{@path}/ajax/lists/update")
      request.set_form_data "list" => json_data.to_json
      response = @http.request request
      response_json = JSON.parse(response.body)

      if response_json["status"] == "success"
        obj.id = nil
        return obj
      end

      false
    end

    def destroy_task(obj)
      json_data = {"list_id" => obj.list_id, "name" => obj.name, "deleted" => 1}

      request = prepare_request(Net::NTTP::Post.new "#{@path}/ajax/tasks/update")
      request.set_form_data "task" => json_data
      response = @http.request request
      response_json = JSON.parse(response.body)

      if response_json["status"] == "success"
        obj.id = nil
        return obj
      end

      false
    end

    def save_task(obj)
      return update_task(obj) if obj.id

      json_data = {"list_id" => obj.list.id, "name" => obj.name, "date" => 0}
      json_data["date"] = obj.date.to_time.to_i if obj.date

      request = prepare_request(Net::HTTP::Post.new "#{@path}/ajax/tasks/insert")
      request.set_form_data "task" => json_data.to_json
      response = @http.request request
      response_json = JSON.parse(response.body)

      if response_json["status"] == "success"
        obj.id = response_json["id"]
        obj.list.tasks << obj
        return obj
      end

      nil
    end

    def update_task(obj)
      json_data = {}
      json_data["id"] = obj.id
      json_data["important"] = obj.important ? 1 : 0
      json_data["done"] = obj.done ? 1 : 0
      json_data["name"] = obj.name
      json_data["date"] = obj.date ? obj.date.to_time.to_i.to_s : "0"

      request = prepare_request(Net::HTTP::Post.new "#{@path}/ajax/tasks/update")
      request.set_form_data "task" => json_data.to_json
      response = @http.request request
      response_json = JSON.parse response.body

      if response_json["status"] == "success"
        return obj
      end

      nil
    end

    def save_list(obj)
      return update_list(obj) if obj.id

      json_data = {"name" => obj.name}
      request = prepare_request(Net::HTTP::Post.new "#{@path}/ajax/lists/insert")
      request.set_form_data "list" => json_data.to_json
      response = @http.request request
      response_json = JSON.parse(response.body)

      if response_json["status"] == "success"
        obj.id = response_json["id"]
        return obj
      end

      nil
    end

    def update_list(obj)
      json_data = {}
      json_data["id"] = obj.id
      json_data["name"] = obj.name

      request = prepare_request(Net::HTTP::Post.new "#{@path}/ajax/lists/update")
      request.set_form_data "list" => json_data.to_json
      response = @http.request request

      if JSON.parse(response.body)["status"] == "success"
        return obj
      end

      nil
    end

    def get_session
      res = @http.request_get("#{@path}/account")
      @session = res["Set-Cookie"].match(/WLSESSID=([0-9a-zA-Z]+)/)[1]
    end

    def load_lists
      request = prepare_request(Net::HTTP::Get.new "#{@path}/ajax/lists/all")
      response = @http.request request
      result = {}
      
      JSON.parse(response.body)["data"].each do |list_elem|
        list = Wunderlist::List.new
        list.id = list_elem[0].to_i
        list.name = list_elem[1]["name"]
        list.inbox = list_elem[1]["inbox"] == "1" ? true : false
        list.shared = list_elem[1]["shared"] == "1" ? true : false
        list.api = self

        result[list.id] = list
      end

      result
    end

    def prepare_request(req)
      req["Cookie"] = "WLSESSID=#{@session}"
      req
    end
  end
end
