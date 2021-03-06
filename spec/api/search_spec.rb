require 'spec_helper'
require 'unicode_shared_examples'

describe 'app' do
  describe 'search' do
    include_context 'search_enabled'

    before (:each) { set_api_key_header }
    let(:author) { create(:user) }
    let(:course_id) { 'test/course/id' }

    def get_result_ids(result)
      result['collection'].map { |t| t['id'] }
    end

    describe "GET /api/v1/search/threads" do
      shared_examples_for 'response for invalid request' do
        before (:each) { TaskHelpers::ElasticsearchHelper.refresh_indices }
        subject { get '/api/v1/search/threads', {course_id: course_id}.merge!(parameters) }

        it { is_expected.to be_ok }
        it { is_expected.to be_an_empty_response }
      end

      context 'without text parameter' do
        let(:parameters) { {} }
        it_behaves_like 'response for invalid request'
      end

      context 'with an invalid sort key' do
        let(:parameters) { {text: 'foobar', sort_key: 'invalid'} }
        it_behaves_like 'response for invalid request'
      end

      describe "search for updated/deleted comment/thread works" do
        let(:course_id) { 'test/course/id' }

        def assert_result_total(expected_total)
          expect(last_response).to be_ok
          result = parse(last_response.body)
          expect(result["total_results"]).to eq(expected_total)
        end

        def create_and_delete_comment_or_thread(factory_name, text)
          comment_or_thread = create(factory_name, course_id: course_id, body: text)
          comment_or_thread.destroy
          TaskHelpers::ElasticsearchHelper.refresh_indices
        end

        def update_comment_or_thread(factory_name, original_text, new_text)
          comment_or_thread = create(factory_name, course_id: course_id, body: original_text)
          comment_or_thread.body = new_text
          comment_or_thread.save!
          TaskHelpers::ElasticsearchHelper.refresh_indices
        end

        it 'returns an empty result if thread is deleted' do
          text = 'thread-to-be-deleted-text'
          create_and_delete_comment_or_thread(:comment_thread, text)

          get '/api/v1/search/threads', course_id: course_id, text: text
          assert_result_total(0)
        end

        it 'returns result only for updated thread' do
          original_text = 'thread-to-be-updated-original-text'
          new_text = 'thread-updated-text'
          update_comment_or_thread(:comment_thread, original_text, new_text)

          get '/api/v1/search/threads', course_id: course_id, text: original_text
          assert_result_total(0)
          get '/api/v1/search/threads', course_id: course_id, text: new_text
          assert_result_total(1)
        end

        it 'returns an empty result if comment is deleted' do
          text = 'comment-to-be-deleted-text'
          create_and_delete_comment_or_thread(:comment, text)

          get '/api/v1/search/threads', course_id: course_id, text: text
          assert_result_total(0)
        end

        it 'returns result only for updated comment' do
          original_text = 'comment-to-be-updated-original-text'
          new_text = 'comment-updated-text'
          update_comment_or_thread(:comment, original_text, new_text)

          get '/api/v1/search/threads', course_id: course_id, text: original_text
          assert_result_total(0)
          get '/api/v1/search/threads', course_id: course_id, text: new_text
          assert_result_total(1)
        end
      end


      describe "filtering works" do
        let!(:threads) do
          threads = (0..34).map do |i|
            thread = make_thread(author, "text", course_id + (i % 2).to_s, "commentable" + (i % 3).to_s)
            if i < 2
              comment = make_comment(author, thread, "objectionable")
              comment.abuse_flaggers = [1]
              comment.save!
            end
            if i % 5 != 0
              thread.group_id = i % 5
              thread.save!
            end
            if [0, 2, 4].include? i
              thread.thread_type = :question
              thread.save!
              comment = make_comment(author, thread, "response")
              comment.save!
            end
            if i > 29
              thread.context = :standalone
              thread.save!
            end
            thread
          end
          TaskHelpers::ElasticsearchHelper.refresh_indices
          threads
        end

        def assert_response_contains(expected_thread_indexes)
          expect(last_response).to be_ok
          result = parse(last_response.body)
          actual_ids = Set.new get_result_ids(result)
          expected_ids = Set.new expected_thread_indexes.map { |i| threads[i].id.to_s }
          expect(actual_ids).to eq(expected_ids)
        end

        it "by course_id" do
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0"
          assert_response_contains((0..29).find_all { |i| i % 2 == 0 })
        end

        it "by context" do
          get "api/v1/search/threads", text: "text", context: "standalone"
          assert_response_contains(30..34)
        end

        it "with unread filter" do
          user = create_test_user(Random.new)
          user.mark_as_read(threads[0])
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", user_id: user.id, unread: true
          assert_response_contains((1..29).find_all { |i| i % 2 == 0 })
        end

        it "with flagged filter" do
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", flagged: true
          assert_response_contains([0])
        end

        it "with unanswered filter" do
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", unanswered: true
          assert_response_contains([0, 2, 4])
          comment = threads[2].comments.first
          comment.endorsed = true
          comment.save!
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", unanswered: true
          assert_response_contains([0, 4])
        end

        it "with unanswered filter and group_id" do
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", unanswered: true
          assert_response_contains([0, 2, 4])
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", unanswered: true, group_id: 2
          assert_response_contains([0, 2])
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", unanswered: true, group_id: 4
          assert_response_contains([0, 4])
          comment = threads[2].comments.first
          comment.endorsed = true
          comment.save!
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", unanswered: true, group_id: 2
          assert_response_contains([0])
        end

        it "by commentable_id" do
          get "/api/v1/search/threads", text: "text", commentable_id: "commentable0"
          assert_response_contains((0..29).find_all { |i| i % 3 == 0 })
        end

        it "by commentable_ids" do
          get "/api/v1/search/threads", text: "text", commentable_ids: "commentable0,commentable1"
          assert_response_contains((0..29).find_all { |i| i % 3 == 0 || i % 3 == 1 })
        end

        it "by group_id" do
          get "/api/v1/search/threads", text: "text", group_id: "1"
          assert_response_contains((0..29).find_all { |i| i % 5 == 0 || i % 5 == 1 })
        end

        it "by group_ids" do
          get "/api/v1/search/threads", text: "text", group_ids: "1,2"
          expected_ids = (0..29).find_all { |i| i % 5 == 0 || i % 5 == 1 || i % 5 == 2 }
          assert_response_contains(expected_ids)
        end

        it "by all filters combined" do
          get "/api/v1/search/threads", text: "text", course_id: "test/course/id0", commentable_id: "commentable0", group_id: "1"
          assert_response_contains([0, 6])
        end
      end

      describe "sorting works" do
        let!(:threads) do
          threads = (0..5).map { |i| make_thread(author, "text", course_id, "dummy") }
          [1, 2].map { |i| author.vote(threads[i], :up) }
          [1, 3].map do |i|
            threads[i].comment_count = 5
            threads[i].save!
          end
          threads[4].save!
          TaskHelpers::ElasticsearchHelper.refresh_indices
          threads
        end

        def check_sort(sort_key, expected_thread_indexes)
          get "/api/v1/search/threads", text: "text", course_id: course_id, sort_key: sort_key
          expect(last_response).to be_ok
          result = parse(last_response.body)
          actual_ids = get_result_ids(result)
          expected_ids = expected_thread_indexes.map { |i| threads[i].id.to_s }
          expect(actual_ids).to eq(expected_ids)
        end

        it "by date" do
          check_sort("date", [5, 4, 3, 2, 1, 0])
        end

        it "by activity" do
          check_sort("activity", [5, 4, 3, 2, 1, 0])
        end

        it "by votes" do
          check_sort("votes", [2, 1, 5, 4, 3, 0])
        end

        it "by comments" do
          check_sort("comments", [3, 1, 5, 4, 2, 0])
        end

        it "by default" do
          check_sort(nil, [5, 4, 3, 2, 1, 0])
        end
      end

      describe "pagination" do
        let!(:threads) do
          threads = (1..50).map { |i| make_thread(author, "text", course_id, "dummy") }
          TaskHelpers::ElasticsearchHelper.refresh_indices
          threads
        end

        def check_pagination(per_page, num_pages)
          result_ids = []
          (1..(num_pages + 1)).each do |i| # Go past the end to make sure non-existent pages are empty
            get "/api/v1/search/threads", text: "text", page: i, per_page: per_page
            expect(last_response).to be_ok
            result = parse(last_response.body)
            result_ids += get_result_ids(result)
          end
          expect(result_ids).to eq(threads.reverse.map { |t| t.id.to_s })
        end

        it "works correctly with page size 1" do
          check_pagination(1, 50)
        end

        it "works correctly with page size 30" do
          check_pagination(30, 2)
        end

        it "works correctly with default page size" do
          check_pagination(nil, 3)
        end
      end

      describe "spelling correction" do
        let(:commentable_id) { "test_commentable" }

        def check_correction(original_text, corrected_text)
          get "/api/v1/search/threads", text: original_text
          expect(last_response).to be_ok
          result = parse(last_response.body)
          expect(result["corrected_text"]).to eq(corrected_text)
          expect(result["collection"].first).not_to be_nil
        end

        before(:each) do
          thread = make_thread(author, "a thread about green artichokes", course_id, commentable_id)
          make_comment(author, thread, "a comment about greed pineapples")
          TaskHelpers::ElasticsearchHelper.refresh_indices
        end

        it "can correct a word appearing only in a comment" do
          check_correction("pinapples", "pineapples")
        end

        it "can correct a word appearing only in a thread" do
          check_correction("arichokes", "artichokes")
        end

        it "can correct a word appearing in both a comment and a thread" do
          check_correction("abot", "about")
        end

        it "can correct a word with multiple errors" do
          check_correction("artcokes", "artichokes")
        end

        it "can correct misspellings in different terms in the same search" do
          check_correction("comment abot pinapples", "comment about pineapples")
        end

        it "does not correct a word that appears in a thread but has a correction and no matches in comments" do
          check_correction("green", nil)
        end

        it "does not correct a word that appears in a comment but has a correction and no matches in threads" do
          check_correction("greed", nil)
        end

        it "does not return a suggestion with no results" do
          # Add documents containing a word that is close to our search term
          # but that do not match our filter criteria; because we currently only
          # consider the top suggestion returned by Elasticsearch without regard
          # to the filter, and that suggestion in this case does not match any
          # results, we should get back no results and no correction.
          10.times do
            thread = make_thread(author, "abbot", "other_course_id", "other_commentable_id")
            thread.group_id = 1
            thread.save!
          end
          TaskHelpers::ElasticsearchHelper.refresh_indices

          get "/api/v1/search/threads", text: "abot", course_id: course_id
          expect(last_response).to be_ok
          result = parse(last_response.body)
          expect(result["corrected_text"]).to be_nil
          expect(result["collection"]).to be_empty
        end
      end

      it 'returns the correct values for total_results and num_pages' do
        course_id = 'test/course/id'
        for i in 1..100 do
          text = "all"
          text += " half" if i % 2 == 0
          text += " quarter" if i % 4 == 0
          text += " tenth" if i % 10 == 0
          text += " one" if i == 100
          # There is currently a bug that causes only 10 threads with matching
          # titles/bodies to be considered, so this test case uses comments.
          create(:comment, course_id: course_id, body: text)
        end
        # Elasticsearch does not necessarily make newly indexed content
        # available immediately, so we must explicitly refresh the index
        TaskHelpers::ElasticsearchHelper.refresh_indices

        test_text = lambda do |text, expected_total_results, expected_num_pages|
          get '/api/v1/search/threads', course_id: course_id, text: text, per_page: '10'
          expect(last_response).to be_ok
          result = parse(last_response.body)
          expect(result["total_results"]).to eq(expected_total_results)
          expect(result["num_pages"]).to eq(expected_num_pages)
        end

        test_text.call("all", 100, 10)
        test_text.call("half", 50, 5)
        test_text.call("quarter", 25, 3)
        test_text.call("tenth", 10, 1)
        test_text.call("one", 1, 1)
      end

      def test_unicode_data(text)
        # Elasticsearch may not be able to handle searching for non-ASCII text,
        # so prepend the text with an ASCII term we can search for.
        search_term = 'artichoke'

        thread = create(:comment_thread, body: "#{search_term} #{text}")
        create(:comment, comment_thread: thread, body: text)
        TaskHelpers::ElasticsearchHelper.refresh_indices

        get '/api/v1/search/threads', course_id: thread.course_id, text: search_term

        expect(last_response).to be_ok
        json = parse(last_response.body)['collection']
        expect(json.length).to eq 1
        check_thread_result_json(nil, thread, json.first)
      end

      include_examples 'unicode data'
    end
  end
end
