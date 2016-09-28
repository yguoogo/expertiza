class LotteryController < ApplicationController

  require 'json'
  require 'rest_client'

  # Give permission to run the bid to appropriate roles
  def action_allowed?
    ['Instructor',
     'Teaching Assistant',
     'Administrator'].include? current_role_name
  end

  # This method is to send request to web service and use k-means and students' bidding data to build teams automatically.
  def run_intelligent_assignment
    priority_info = []
    topic_ids = SignUpTopic.where(assignment_id: params[:id]).map(&:id)
    user_ids = Participant.where(parent_id: params[:id]).map(&:user_id)
    user_ids.each do |user_id|
      #grab student id and list of bids
      bids = []
      topic_ids.each do |topic_id|
        bid_record = Bid.where(user_id: user_id, topic_id: topic_id).first rescue nil
        if bid_record.nil?
          bids << 0
        else
          bids << bid_record.priority ||= 0
        end
      end
      if bids.uniq != [0] and ![6864, 6865, 6866, 6855].include? user_id
        priority_info << {pid: user_id, ranks: bids}
      end
    end
    assignment = Assignment.find_by_id(params[:id])
    data = {users: priority_info, max_team_size: assignment.max_team_size}
    url = WEBSERVICE_CONFIG["topic_bidding_webservice_url"]
    begin
      response = RestClient.post url, data.to_json, :content_type => :json, :accept => :json
      # store each summary in a hashmap and use the question as the key
      teams = JSON.parse(response)["teams"]
    rescue => err
      flash[:error] = err.message
    end
    create_new_teams_for_bidding_response(teams, assignment)

    redirect_to controller: 'tree_display', action: 'list'
  end

  def create_new_teams_for_bidding_response(teams, assignment)
    teams.each_with_index do |user_ids, index|
      new_team = AssignmentTeam.create(name: assignment.name + '_Team' + rand(1000).to_s, 
                                       parent_id: assignment.id, 
                                       type: 'AssignmentTeam')
      parent = TeamNode.create(parent_id: assignment.id, node_object_id: new_team.id)
      user_ids.each do |user_id|
        team_user = TeamsUser.where(user_id: user_id, team_id: new_team.id).first rescue nil
        team_user = TeamsUser.create(user_id: user_id, team_id: new_team.id) if team_user.nil?
        TeamUserNode.create(parent_id: parent.id, node_object_id: team_user.id) 
      end
    end
  end

  # This method is called for assignments which have their is_intelligent property set to 1. It runs a stable match algorithm and assigns topics
  # to strongest contenders (team strength, priority of bids)
  def run_intelligent_bid
    unless Assignment.find_by_id(params[:id]).is_intelligent # if the assignment is intelligent then redirect to the tree display list
      flash[:error] = "This action not allowed. The assignment " + Assignment.find_by_id(params[:id]).name + " does not enabled intelligent assignments."
      redirect_to controller: 'tree_display', action: 'list'
      return
    end

    finalTeamTopics = {} # Hashmap (Team,Topic) to store teams which have been assigned topics
    # unassignedTeams = Bid.where(topic: SignUpTopic.where(assignment_id: params[:id])).uniq.pluck(:team_id) # Get all unassigned teams,. Will be used for merging
    unassignedTeams = Team.where(parent_id: params[:id]).reject {|t| !SignedUpTeam.where(team_id: t.id).empty?}
    sign_up_topics = SignUpTopic.includes(bids: [{team: [:users]}]).where("assignment_id = ? and max_choosers > 0", params[:id]) # Getting signuptopics with max_choosers > 0
    topicsBidsArray = []
    sign_up_topics.each do |topic|
      team_bids = []
      unassignedTeams.each do |team|
        student_bids = []
        TeamsUser.where(team_id: team).each do |s|
          puts s.user_id
          puts topic.id
          if !Bid.where(team_id: s.user_id, topic_id: topic.id).empty?
            student_bids<< Bid.where(team_id: s.user_id, topic_id: topic.id).first.priority
          else
            student_bids << 0
          end
        end
        freq = student_bids.inject(Hash.new(0)) { |h,v| h[v] += 1; h}
        team_bids << {team_id: team.id,priority: student_bids.max_by { |v| freq[v] }}
      end
      topicsBidsArray << [topic,team_bids.sort_by {|b| [TeamsUser.where(["team_id = ?", b[:team_id]]).count * -1, b[:priority], rand(100)] }]
    end
    puts topicsBidsArray
   
    redirect_to controller: 'tree_display', action: 'list'
  end

  # This method is called to automerge smaller teams to teams which were assigned topics through intelligent assignment
  def auto_merge_teams(unassignedTeams, _finalTeamTopics)
    assignment = Assignment.find(params[:id])
    # Sort unassigned
    unassignedTeams = Team.where(id: unassignedTeams).sort_by {|t| !t.users.size }
    unassignedTeams.each do |team|
      sortedBids = Bid.where(team_id: team.id).sort_by(&:priority) # Get priority for each unassignmed team
      sortedBids.each do |b|
        # SignedUpTeam.where(:topic=>b.topic_id).first.team_id
        winningTeam = SignedUpTeam.where(topic: b.topic_id).first.team_id
        next unless TeamsUser.where(team_id: winningTeam).size + team.users.size <= assignment.max_team_size # If the team can be merged to a bigger team
        TeamsUser.where(team_id: team.id).update_all(team_id: winningTeam)
        Bid.delete_all(team_id: team.id)
        Team.delete(team.id)
        break
      end
    end
  end
end
