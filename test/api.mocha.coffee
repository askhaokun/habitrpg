_ = require 'underscore'
request = require 'superagent'
expect = require 'expect.js'
utils = require 'derby-auth/utils'
require 'coffee-script'

## monkey-patch expect.js for better diffs on mocha
## see: https://github.com/LearnBoost/expect.js/pull/34

origBe = expect.Assertion::be
expect.Assertion::be = expect.Assertion::equal = (obj) ->
  @_expected = obj
  origBe.call this, obj

# Custom modules
scoring = require '../src/app/scoring'
character = require '../src/app/character'
config = require './config'

###### Helpers & Variables ######

model = null
uuid = null
taskPath = null
baseURL = 'http://localhost:1337/api/v1'

###### Specs ######

describe 'API', ->
  server = null
  store = null
  model = null
  user = null
  uid = null

  before (done) ->
    server = require '../src/server'
    server.listen '1337', '0.0.0.0'
    server.on 'listening', (data) ->
      store = server.habitStore
      #store.flush()
      model = store.createModel()
      model.set '_userId', uid = model.id()
      user = character.newUserObject()
      user.apiToken = model.id()
      user.email = 'foo@bar.com'
      #phish
      user.password = 'da337d52075f55ba4b16636635e913f83854433d'
      console.log user.password

      model.set "users.#{uid}", user
      # Crappy hack to let server start before tests run
      setTimeout done, 2000

  describe 'Without token or user id', ->

    it '/api/v1/status', (done) ->
      request.get("#{baseURL}/status")
        .set('Accept', 'application/json')
        .end (res) ->
          expect(res.statusCode).to.be 200
          expect(res.body.status).to.be 'up'
          done()

    it '/api/v1/user', (done) ->
      request.get("#{baseURL}/user")
        .set('Accept', 'application/json')
        .end (res) ->
          expect(res.statusCode).to.be 401
          expect(res.body.err).to.be 'You must include a token and uid (user id) in your request'
          done()

  describe 'With token and user id', ->
    params = null
    currentUser = null

    before ->
      user = model.at("users.#{uid}")
      currentUser = user.get()
      params =
        title: 'Title'
        text: 'Text'
        type: 'habit'

    beforeEach ->
      currentUser = user.get()

    it '/api/v1/user/auth', (done) ->
      request.post("#{baseURL}/user/auth")
        .set('Accept', 'application/json')
        .send(email: currentUser.email, password: 'phish')
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body.token).to.be currentUser.apiKey
          expect(res.body.uid).to.be currentUser.id
          done()

    it 'GET /api/v1/user', (done) ->
      request.get("#{baseURL}/user")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body.id).not.to.be.empty()
          self = _.clone(currentUser)
          delete self[val] for val in ['tasks', 'apiToken', 'flags', 'lastCron']

          expect(res.body).to.eql self
          done()

    it 'GET /api/v1/task/:id', (done) ->
      tid = _.pluck(currentUser.tasks, 'id')[0]
      request.get("#{baseURL}/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body).to.eql currentUser.tasks[tid]
          done()

    it 'POST /api/v1/user/task', (done) ->
      request.post("#{baseURL}/user/task")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(params)
        .end (res) ->
          query = model.query('users').withIdAndToken(currentUser.id, currentUser.apiToken)
          query.fetch (err, user) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 201
            expect(res.body.id).not.to.be.empty()
            # Ensure that user owns the newly created object
            expect(user.at(0).get().tasks[res.body.id]).to.be.an('object')
            done()

    it 'PUT /api/v1/task/:id', (done) ->
      tid = _.pluck(currentUser.tasks, 'id')[0]
      request.put("#{baseURL}/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(title: 'a new title')
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          currentUser.tasks[tid].title = 'a new title'
          expect(res.body).to.eql currentUser.tasks[tid]
          done()

    it 'GET /api/v1/user/tasks', (done) ->
      request.get("#{baseURL}/user/tasks")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          query = model.query('users').withIdAndToken(currentUser.id, currentUser.apiToken)
          query.fetch (err, user) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 200
            currentUser = user.at(0).get()
            model.ref '_user', user.at(0)
            tasks = []
            for type in ['habit','todo','daily','reward']
              model.refList "_#{type}List", "_user.tasks", "_user.#{type}Ids"
              tasks = tasks.concat model.get("_#{type}List")
            # Ensure that user owns the tasks
            expect(res.body.length).to.equal tasks.length
            # Ensure that the two sets are equal
            expect(_.difference(_.pluck(res.body,'id'), _.pluck(tasks,'id')).length).to.equal 0
            done()

    it 'GET /api/v1/user/tasks (todos)', (done) ->
      request.get("#{baseURL}/user/tasks")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .query(type:'todo')
        .end (res) ->
          query = model.query('users').withIdAndToken(currentUser.id, currentUser.apiToken)
          query.fetch (err, user) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 200
            currentUser = user.at(0).get()
            model.ref '_user', user.at(0)
            model.refList "_todoList", "_user.tasks", "_user.todoIds"
            tasks = model.get("_todoList")
            # Ensure that user owns the tasks
            expect(res.body.length).to.equal tasks.length
            # Ensure that the two sets are equal
            expect(_.difference(_.pluck(res.body,'id'), _.pluck(tasks,'id')).length).to.equal 0
            done()
