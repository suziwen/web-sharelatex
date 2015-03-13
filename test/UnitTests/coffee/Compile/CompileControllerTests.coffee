sinon = require('sinon')
chai = require('chai')
should = chai.should()
assert = require("chai").assert
expect = chai.expect
modulePath = "../../../../app/js/Features/Compile/CompileController.js"
SandboxedModule = require('sandboxed-module')
MockRequest = require "../helpers/MockRequest"
MockResponse = require "../helpers/MockResponse"

describe "CompileController", ->
	beforeEach ->
		@CompileManager = 
			compile: sinon.stub()
		@ClsiManager = {}
		@UserGetter = 
			getUser:sinon.stub()
		@CompileController = SandboxedModule.require modulePath, requires:
			"settings-sharelatex": @settings =
				apis:
					clsi:
						url: "clsi.example.com"
					clsi_priority:
						url: "clsi-priority.example.com"
			"request": @request = sinon.stub()
			"../../models/Project": Project: @Project = {}
			"logger-sharelatex": @logger = { log: sinon.stub(), error: sinon.stub() }
			"../../infrastructure/Metrics": @Metrics =  { inc: sinon.stub() }
			"./CompileManager":@CompileManager
			"./ClsiManager": @ClsiManager
			"../Authentication/AuthenticationController": @AuthenticationController = {}
		@project_id = "project-id"
		@session_id = "mock-session-id"
		@user = 
			features:
				compileGroup: "premium"
				compileTimeout: 100
		@next = sinon.stub()
		@req = new MockRequest()
		@res = new MockResponse()

	describe "compile", ->

		describe "when not an auto compile", ->
			beforeEach ->
				@req.params =
					Project_id: @project_id
				@req.session = {}
				@req.body =
					session_id: @session_id
				@AuthenticationController.getLoggedInUserId = sinon.stub().callsArgWith(1, null, @user_id = "mock-user-id")
				@CompileManager.compile = sinon.stub().callsArgWith(4, null, @status = "success", @outputFiles = ["mock-output-files"], @output = "mock-output")
				@CompileController.compile @req, @res, @next

			it "should look up the user id", ->
				@AuthenticationController.getLoggedInUserId
					.calledWith(@req)
					.should.equal true

			it "should do the compile without the auto compile flag", ->
				@CompileManager.compile
					.calledWith(@project_id, @user_id, @session_id, { isAutoCompile: false })
					.should.equal true

			it "should set the content-type of the response to application/json", ->
				@res.contentType
					.calledWith("application/json")
					.should.equal true

			it "should send a successful response reporting the status and files", ->
				@res.statusCode.should.equal 200
				@res.body.should.equal JSON.stringify({
					status: @status
					outputFiles: @outputFiles
					output: @output
				})

		describe "when an auto compile", ->
			beforeEach ->
				@req.params =
					Project_id: @project_id
				@req.query =
					auto_compile: "true"
				@req.body =
					session_id: @session_id
				@AuthenticationController.getLoggedInUserId = sinon.stub().callsArgWith(1, null, @user_id = "mock-user-id")
				@CompileManager.compile = sinon.stub().callsArgWith(4, null, @status = "success", @outputFiles = ["mock-output-files"])
				@CompileController.compile @req, @res, @next

			it "should do the compile with the auto compile flag", ->
				@CompileManager.compile
					.calledWith(@project_id, @user_id, @session_id, { isAutoCompile: true })
					.should.equal true

	describe "downloadPdf", ->
		beforeEach ->
			@req.params =
				Project_id: @project_id
			@project =
				getSafeProjectName: () => @safe_name = "safe-name"
				
			@Project.findById = sinon.stub().callsArgWith(2, null, @project)

		describe "when downloading for embedding", ->
			beforeEach ->
				@project.useClsi2 = true
				@CompileController.proxyToClsi = sinon.stub()
				@CompileController.downloadPdf(@req, @res, @next)

			it "should look up the project", ->
				@Project.findById
					.calledWith(@project_id, {name: 1})
					.should.equal true

			it "should set the content-type of the response to application/pdf", ->
				@res.contentType
					.calledWith("application/pdf")
					.should.equal true

			it "should set the content-disposition header with the project name", ->
				@res.header
					.calledWith("Content-Disposition", "filename=#{@safe_name}.pdf")
					.should.equal true

			it "should increment the pdf-downloads metric", ->
				@Metrics.inc
					.calledWith("pdf-downloads")
					.should.equal true

			it "should proxy the PDF from the CLSI", ->
				@CompileController.proxyToClsi
					.calledWith(@project_id, "/project/#{@project_id}/output/output.pdf", @req, @res, @next)
					.should.equal true

	describe "proxyToClsi", ->
		beforeEach ->
			@request.returns(@proxy = {
				pipe: sinon.stub()
				on: sinon.stub()
			})
			@upstream =
				statusCode: 204
				headers: { "mock": "header" }
			@req.method = "mock-method"
			@req.headers = {
				'Mock': 'Headers',
				'Range': '123-456'
				'If-Range': 'abcdef'
				'If-Modified-Since': 'Mon, 15 Dec 2014 15:23:56 GMT'
			}

		describe "old pdf viewer", ->
			describe "user with standard priority", ->
				beforeEach ->
					@CompileManager.getProjectCompileLimits = sinon.stub().callsArgWith(1, null, {compileGroup: "standard"})
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should open a request to the CLSI", ->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi.url}#{@url}",
							timeout: 60 * 1000
						)
						.should.equal true

				it "should pass the request on to the client", ->
					@proxy.pipe
						.calledWith(@res)
						.should.equal true

				it "should bind an error handle to the request proxy", ->
					@proxy.on.calledWith("error").should.equal true

			describe "user with priority compile", ->
				beforeEach ->
					@CompileManager.getProjectCompileLimits = sinon.stub().callsArgWith(1, null, {compileGroup: "priority"})
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should proxy to the priority url if the user has the feature", ()->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi_priority.url}#{@url}",
							timeout: 60 * 1000
						)
						.should.equal true

			describe "user with standard priority via query string", ->
				beforeEach ->
					@req.query = {compileGroup: 'standard'}
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should open a request to the CLSI", ->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi.url}#{@url}",
							timeout: 60 * 1000
						)
						.should.equal true

				it "should pass the request on to the client", ->
					@proxy.pipe
						.calledWith(@res)
						.should.equal true

				it "should bind an error handle to the request proxy", ->
					@proxy.on.calledWith("error").should.equal true

			describe "user with priority compile via query string", ->
				beforeEach ->
					@req.query = {compileGroup: 'priority'}
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should proxy to the priority url if the user has the feature", ()->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi_priority.url}#{@url}",
							timeout: 60 * 1000
						)
						.should.equal true

			describe "user with non-existent priority via query string", ->
				beforeEach ->
					@req.query = {compileGroup: 'foobar'}
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should proxy to the standard url", ()->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi.url}#{@url}",
							timeout: 60 * 1000
						)
						.should.equal true

			describe "user with build parameter via query string", ->
				beforeEach ->
					@CompileManager.getProjectCompileLimits = sinon.stub().callsArgWith(1, null, {compileGroup: "standard"})
					@req.query = {build: 1234}
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should proxy to the standard url without the build parameter", ()->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi.url}#{@url}",
							timeout: 60 * 1000
						)
						.should.equal true

		describe "new pdf viewer", ->
			beforeEach ->
				@req.query = {pdfng: true}
			describe "user with standard priority", ->
				beforeEach ->
					@CompileManager.getProjectCompileLimits = sinon.stub().callsArgWith(1, null, {compileGroup: "standard"})
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should open a request to the CLSI", ->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi.url}#{@url}",
							timeout: 60 * 1000
							headers: {
								'Range': '123-456'
								'If-Range': 'abcdef'
								'If-Modified-Since': 'Mon, 15 Dec 2014 15:23:56 GMT'
							}
						)
						.should.equal true

				it "should pass the request on to the client", ->
					@proxy.pipe
						.calledWith(@res)
						.should.equal true

				it "should bind an error handle to the request proxy", ->
					@proxy.on.calledWith("error").should.equal true

			describe "user with priority compile", ->
				beforeEach ->
					@CompileManager.getProjectCompileLimits = sinon.stub().callsArgWith(1, null, {compileGroup: "priority"})
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should proxy to the priority url if the user has the feature", ()->
					@request
						.calledWith(
							method: @req.method
							url: "#{@settings.apis.clsi_priority.url}#{@url}",
							timeout: 60 * 1000
							headers: {
								'Range': '123-456'
								'If-Range': 'abcdef'
								'If-Modified-Since': 'Mon, 15 Dec 2014 15:23:56 GMT'
							}
						)
						.should.equal true

			describe "user with build parameter via query string", ->
				beforeEach ->
					@CompileManager.getProjectCompileLimits = sinon.stub().callsArgWith(1, null, {compileGroup: "standard"})
					@req.query = {build: 1234, pdfng: true}
					@CompileController.proxyToClsi(@project_id, @url = "/test", @req, @res, @next)

				it "should proxy to the standard url with the build parameter", ()->
					@request
						.calledWith(
							method: @req.method
							qs: {build: 1234}
							url: "#{@settings.apis.clsi.url}#{@url}",
							timeout: 60 * 1000
							headers: {
								'Range': '123-456'
								'If-Range': 'abcdef'
								'If-Modified-Since': 'Mon, 15 Dec 2014 15:23:56 GMT'
							}
						)
						.should.equal true

	describe "deleteAuxFiles", ->
		beforeEach ->
			@CompileManager.deleteAuxFiles = sinon.stub().callsArg(1)
			@req.params =
				Project_id: @project_id
			@res.send = sinon.stub()
			@CompileController.deleteAuxFiles @req, @res, @next

		it "should proxy to the CLSI", ->
			@CompileManager.deleteAuxFiles
				.calledWith(@project_id)
				.should.equal true

		it "should return a 200", ->
			@res.send
				.calledWith(200)
				.should.equal true

	describe "compileAndDownloadOutput", ->
		beforeEach ->
			@req =
				params:
					project_id:@project_id
			@outputFiles = [{
				path: "main.png"
			}, {
				path: "other.csv"
			}]
			@CompileManager.compile.callsArgWith(3, null, "success", @outputFiles)
			@CompileManager.sortOutputFiles = sinon.stub().returns(@outputFiles)
			@CompileController.proxyToClsi = sinon.stub()
			@res = 
				send:=>
									
		it "should call compile in the compile manager", (done)->
			@CompileController.compileAndDownloadOutput @req, @res
			@CompileManager.compile.calledWith(@project_id).should.equal true
			done()

		it "should proxy the res to the clsi with correct url", (done)->
			@CompileController.compileAndDownloadOutput @req, @res
			@CompileController.proxyToClsi.calledWith(@project_id, "/project/#{@project_id}/output/main.png", @req, @res).should.equal true
			done()
