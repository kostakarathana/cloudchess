import XCTest
import UIKit
import StoreKitTest
final class CloudChessUITests:XCTestCase {
    /// Captures real rendered gameplay; no composited or invented app UI.
    func testAppStoreScreenshotSet() throws {
        continueAfterFailure=false
        for (name,shape,mate) in [("01-checkmate","6x6",2),("02-winning-moves","8x8",0),("03-small-board","5x5",1),("04-rectangular-board","4x6",2)] {
            let app=XCUIApplication()
            app.launchArguments=["--uitesting","--board=\(shape)","--puzzle-mate=\(mate)","--reduced-motion"]
            app.launch();puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["boardMatches"],"1")
            XCTAssertEqual(puzzleValues(app)["error"],"0")
            XCTAssertTrue(app.buttons["Settings"].isHittable)
            let shot=XCTAttachment(screenshot:app.screenshot())
            shot.name="store-\(name)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    /// Marketing captures: real rendered gameplay with a seeded score; captions are added outside the app.
    func testMarketingScreenshotSet() throws {
        continueAfterFailure=false
        for (name,shape,mate,night) in [("m1-hero-8x8","8x8",2,false),("m2-winning-6x6","6x6",0,false),("m3-small-5x5","5x5",1,false),("m4-rect-4x6","4x6",2,false),("m5-night-7x7","7x7",2,true),("m6-wide-8x5","8x5",0,false)] {
            let app=XCUIApplication()
            app.launchArguments=["--uitesting","--board=\(shape)","--puzzle-mate=\(mate)","--score=842310","--reduced-motion"]+(night ? ["--night"]:[])
            app.launch();puzzleReady(app,timeout:120)
            XCTAssertEqual(puzzleValues(app)["error"],"0")
            // Let the brief side pulse finish so the board is still.
            let clear=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulsing:0"),object:app.otherElements["puzzle-status"])
            _=XCTWaiter.wait(for:[clear],timeout:10);Thread.sleep(forTimeInterval:1.5)
            if app.descendants(matching:.any)["instruction-panel"].exists {dismissInstructions(app);_=XCTWaiter.wait(for:[clear],timeout:10);Thread.sleep(forTimeInterval:1.5)}
            let shot=XCTAttachment(screenshot:app.screenshot())
            shot.name="marketing-\(name)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    /// Real renders of tutorial positions plus each square's projected board-plane
    /// centre; scripts/build_tutorial_art.swift adds the arrows and badges.
    func testTutorialArtCaptures() throws {
        continueAfterFailure=false
        func capture(_ app:XCUIApplication,_ name:String) {
            let clear=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulsing:0"),object:app.otherElements["puzzle-status"])
            _=XCTWaiter.wait(for:[clear],timeout:10);Thread.sleep(forTimeInterval:1.2)
            var centres:[String:[Double]]=[:]
            for element in app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","board-plane-")).allElementsBoundByIndex {
                centres[String(element.identifier.dropFirst(12))]=[Double(element.frame.midX),Double(element.frame.midY)]
            }
            let bar=app.otherElements["material-bar"]
            var meta:[String:Any]=["centres":centres,"width":Double(app.frame.width),"height":Double(app.frame.height),"status":app.otherElements["puzzle-status"].value as? String ?? ""]
            if bar.exists {meta["bar"]=[bar.frame.minX,bar.frame.minY,bar.frame.width,bar.frame.height].map(Double.init)}
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="tutorial-\(name)";shot.lifetime = .keepAlways;add(shot)
            let data=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:meta,options:[.sortedKeys]),uniformTypeIdentifier:"public.json")
            data.name="tutorial-\(name)-meta";data.lifetime = .keepAlways;add(data)
        }
        // Mate in 2 (white): Re5+ Rd5 Rxd5#. The wrong first move Re4 leaves no mate.
        var app=XCUIApplication()
        app.launchArguments=["--uitesting","--tutorial-fixture=7bd568da28d70a64982872c0","--reduced-motion","--cloud-validation","--tutorial-capture","--score=42180"]
        app.launch();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["id"],"7bd568da28d70a64982872c0-0")
        capture(app,"mate-start")
        puzzleMove(app,"e2e4");puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["moves"],"2");XCTAssertNotEqual(puzzleValues(app)["offTrack"],"-1")
        capture(app,"mate-offtrack")
        app.terminate()
        // Improve in 2 (white): Nb4+ forks king and rook, then Nxa6.
        app=XCUIApplication()
        app.launchArguments=["--uitesting","--tutorial-fixture=ddec583138a388ce3824010e","--reduced-motion","--cloud-validation","--tutorial-capture","--hold-completion","--score=42180"]
        app.launch();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["id"],"ddec583138a388ce3824010e-0")
        capture(app,"improve-start")
        puzzleMove(app,"c2b4");puzzleReady(app)
        puzzleMove(app,"b4a6")
        let won=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","phase:won,"),object:app.otherElements["puzzle-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[won],timeout:40),.completed)
        Thread.sleep(forTimeInterval:2.5)
        capture(app,"improve-won")
        app.terminate()
    }
    /// Opens the Premium panel from a due ad break (free play has no hard paywall).
    private func openPremiumFromAdBreak(_ app:XCUIApplication) {
        XCTAssertTrue(app.descendants(matching:.any)["ad-break-panel"].waitForExistence(timeout:45))
        app.buttons["ad-break-premium"].tap()
    }
    /// App Review screenshot of the Premium card with both plans (DEBUG plan fixture).
    @MainActor func testPremiumReviewScreenshot() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--premium-preview","--reduced-motion"]
        app.launch();openPremiumFromAdBreak(app)
        XCTAssertTrue(app.staticTexts["subscription-annual-price"].waitForExistence(timeout:20))
        XCTAssertEqual(app.staticTexts["subscription-savings"].label,"Save 37%")
        XCTAssertEqual(app.staticTexts["subscription-terms"].label,"Free for 1 month, then $59.99 per year. Auto-renews until canceled.")
        XCTAssertEqual(app.buttons["subscription-buy"].label,"Start free trial")
        Thread.sleep(forTimeInterval:1)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="premium-review";shot.lifetime = .keepAlways;add(shot)
        app.buttons["subscription-plan-monthly"].tap()
        XCTAssertEqual(app.staticTexts["subscription-terms"].label,"Free for 7 days, then $7.99 per month. Auto-renews until canceled.")
        let monthly=XCTAttachment(screenshot:app.screenshot());monthly.name="premium-review-monthly";monthly.lifetime = .keepAlways;add(monthly)
    }
    @MainActor func testSubscriptionPurchaseRestoreAndRevocation() throws {
        continueAfterFailure=false
        let store=try SKTestSession(configurationFileNamed:"CloudChess")
        store.resetToDefaultState();store.clearTransactions();store.disableDialogs=true
        defer {store.clearTransactions()}
        let app=XCUIApplication()
        app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--reduced-motion"]
        app.launch();openPremiumFromAdBreak(app)
        let buy=app.buttons["subscription-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout:45))
        let priced=XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:buy)
        XCTAssertEqual(XCTWaiter.wait(for:[priced],timeout:20),.completed)
        XCTAssertTrue(app.staticTexts["subscription-price"].label.contains("7.99"))
        XCTAssertTrue(app.staticTexts["subscription-annual-price"].label.contains("59.99"))
        XCTAssertEqual(app.staticTexts["subscription-savings"].label,"Save 37%","59.99 vs 12 × 7.99, rounded down")
        XCTAssertTrue(app.staticTexts["1-month free trial"].exists);XCTAssertTrue(app.staticTexts["7-day free trial"].exists)
        XCTAssertEqual(buy.label,"Start free trial")
        XCTAssertEqual(app.staticTexts["subscription-terms"].label,"Free for 1 month, then $59.99 per year. Auto-renews until canceled.")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Premium plans with trials";shot.lifetime = .keepAlways;add(shot)
        app.buttons["subscription-plan-monthly"].tap()
        XCTAssertEqual(app.staticTexts["subscription-terms"].label,"Free for 7 days, then $7.99 per month. Auto-renews until canceled.")
        buy.tap()
        XCTAssertTrue(app.staticTexts["subscription-active"].waitForExistence(timeout:20))
        app.buttons["subscription-continue"].tap();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["unlimited"],"1")
        // Relaunch: StoreKit restores entitlement itself; no ad break.
        app.terminate();app.launchArguments=["--uitesting","--monetization-testing","--preserve-allowance","--preserve-coach","--reduced-motion"]
        app.launch();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["unlimited"],"1");XCTAssertEqual(puzzleValues(app)["adBreak"],"0")
        app.buttons["Settings"].tap();app.buttons["Premium"].tap()
        try store.expireSubscription(productIdentifier:"com.maroon.CloudChess.unlimited.monthly")
        XCTAssertTrue(app.buttons["subscription-restore"].waitForExistence(timeout:20))
        app.buttons["subscription-restore"].tap()
        XCTAssertTrue(app.staticTexts["No active subscription was found for this Apple Account."].waitForExistence(timeout:20))
    }
    @MainActor func testSubscriptionPendingDoesNotUnlock() throws {
        continueAfterFailure=false
        let store=try SKTestSession(configurationFileNamed:"CloudChess")
        store.resetToDefaultState();store.clearTransactions();store.disableDialogs=true;store.askToBuyEnabled=true
        defer {store.clearTransactions()}
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--reduced-motion"]
        app.launch();openPremiumFromAdBreak(app);let buy=app.buttons["subscription-buy"]
        XCTAssertTrue(buy.waitForExistence(timeout:45))
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"enabled == true"),object:buy)],timeout:20),.completed)
        buy.tap()
        XCTAssertTrue(app.staticTexts["subscription-message"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["subscription-message"].label.contains("approval"))
        XCTAssertFalse(app.buttons["subscription-continue"].exists)
        let transaction=try XCTUnwrap(store.allTransactions().last)
        try store.approveAskToBuyTransaction(identifier:transaction.identifier)
        XCTAssertTrue(app.staticTexts["subscription-active"].waitForExistence(timeout:20))
        try store.refundTransaction(identifier:transaction.identifier)
        XCTAssertTrue(app.buttons["subscription-buy"].waitForExistence(timeout:20))
        XCTAssertFalse(app.buttons["subscription-continue"].exists)
    }
    @MainActor func testSubscriptionLargeTextAndDismissal() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--reduced-motion","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();openPremiumFromAdBreak(app)
        let close=app.buttons["Close cloudchess premium"]
        XCTAssertTrue(close.waitForExistence(timeout:30))
        XCTAssertTrue(close.isHittable);XCTAssertTrue(app.frame.contains(close.frame))
        XCTAssertTrue(app.buttons["subscription-restore"].isHittable)
        XCTAssertTrue(app.buttons["subscription-buy"].exists)
        XCTAssertFalse(app.buttons["square-a1"].exists)
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Accessible Premium panel";image.lifetime = .keepAlways;add(image)
        close.tap()
        XCTAssertTrue(app.descendants(matching:.any)["ad-break-panel"].waitForExistence(timeout:5),"Closing Premium returns to the ad break, not a dead end")
        XCTAssertTrue(app.buttons["ad-break-short"].isHittable);XCTAssertTrue(app.buttons["ad-break-long"].exists)
    }
    /// After the introduction, a short ad grants a pace-sized batch; the admitted puzzle resumes free.
    @MainActor func testAdBreakShortAdGrantsBatchAndResume() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--fast-ads","--board=6x6","--reduced-motion"]
        app.launch()
        XCTAssertTrue(app.descendants(matching:.any)["ad-break-panel"].waitForExistence(timeout:45))
        XCTAssertFalse(app.buttons["square-a1"].exists,"The ad break blocks the board")
        XCTAssertEqual(puzzleValues(app)["adOffer"],"4|16","No pace history yet: a minute per puzzle")
        XCTAssertEqual(app.buttons["ad-break-short"].label,"Watch a short ad, 4 more puzzles")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Ad break choice";shot.lifetime = .keepAlways;add(shot)
        app.buttons["ad-break-short"].tap()
        let close=app.buttons["house-ad-close"];XCTAssertTrue(close.waitForExistence(timeout:10))
        let ad=XCTAttachment(screenshot:app.screenshot());ad.name="Premium house ad (no fill)";ad.lifetime = .keepAlways;add(ad)
        close.tap();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["freeRemaining"],"3","Four granted, one used by this puzzle")
        let id=puzzleValues(app)["id"]
        app.terminate();app.launchArguments=["--uitesting","--monetization-testing","--preserve-allowance","--preserve-coach","--board=6x6","--reduced-motion"]
        app.launch();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["id"],id);XCTAssertEqual(puzzleValues(app)["freeRemaining"],"3","Resuming never spends another puzzle")
        for remaining in [2,1,0] {
            app.buttons["Skip puzzle"].tap();app.buttons["confirm-action"].tap();puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["freeRemaining"],String(remaining))
        }
        // The batch is used, but the four-minute gap since the break keeps play free.
        app.buttons["Skip puzzle"].tap();app.buttons["confirm-action"].tap();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["adBreak"],"0")
    }
    /// After a completed ad break that reaches the 2–4 break interval, the Premium
    /// card offers both plans and their free trials once; "Not now" returns to play.
    @MainActor func testPremiumPromptAfterAdBreaks() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--fast-ads","--premium-preview","--upsell-every=1","--board=6x6","--reduced-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["ad-break-short"].waitForExistence(timeout:45))
        XCTAssertEqual(puzzleValues(app)["premiumPrompt"],"0","Never before an ad has been watched")
        app.buttons["ad-break-short"].tap()
        let close=app.buttons["house-ad-close"];XCTAssertTrue(close.waitForExistence(timeout:10));close.tap()
        let banner=app.descendants(matching:.any)["subscription-trial-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout:20),"The prompt follows the completed break")
        XCTAssertTrue(banner.label.contains("1 month free with yearly") && banner.label.contains("7 days free with monthly"),banner.label)
        XCTAssertTrue(app.buttons["subscription-plan-annual"].exists && app.buttons["subscription-plan-monthly"].exists)
        XCTAssertEqual(app.buttons["subscription-buy"].label,"Start free trial")
        XCTAssertEqual(puzzleValues(app)["premiumPrompt"],"1");XCTAssertEqual(puzzleValues(app)["upsellShown"],"1")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Premium prompt after ads";shot.lifetime = .keepAlways;add(shot)
        app.buttons["subscription-not-now"].tap()
        puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["premiumPrompt"],"0");XCTAssertFalse(banner.exists)
        XCTAssertEqual(puzzleValues(app)["freeRemaining"],"3","The granted batch is unaffected")
    }
    @MainActor func testAdBreakLongBundleAndBackgroundForfeit() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--fast-ads","--reduced-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["ad-break-long"].waitForExistence(timeout:45))
        app.buttons["ad-break-long"].tap()
        // Leaving during an ad forfeits that break; it is offered again with the same sizes.
        XCTAssertTrue(app.descendants(matching:.any)["house-ad"].waitForExistence(timeout:10))
        XCUIDevice.shared.press(.home);Thread.sleep(forTimeInterval:1);app.activate()
        XCTAssertFalse(app.buttons["continue-session"].exists,"Returning never shows a continue card")
        XCTAssertTrue(app.buttons["ad-break-long"].waitForExistence(timeout:20))
        XCTAssertEqual(puzzleValues(app)["adOffer"],"4|16");XCTAssertEqual(puzzleValues(app)["freeRemaining"],"0")
        app.buttons["ad-break-long"].tap()
        for n in 1...3 {
            let close=app.buttons["house-ad-close"];XCTAssertTrue(close.waitForExistence(timeout:10),"Ad \(n) of 3")
            close.tap()
        }
        puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["freeRemaining"],"15","Sixteen granted after all three ads, one used")
    }
    /// The real Google Mobile Ads SDK with Google's sample rewarded unit (DEBUG builds never request
    /// live ads): consent/IDFA messages, load, present, reward callback, batch grant and resume.
    @MainActor func testGoogleSampleRewardedAdGrantsBatch() throws {
        continueAfterFailure=false
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--ad-break-due","--real-ads","--board=6x6","--reduced-motion"]
        app.launch()
        var deadline=Date().addingTimeInterval(120)
        while puzzleValues(app)["googleAd"] != "loaded",Date()<deadline {answerAdPrompts(app,springboard);Thread.sleep(forTimeInterval:1)}
        XCTAssertEqual(puzzleValues(app)["googleAd"],"loaded","Google's sample ad loads: \(puzzleValues(app)["googleAd"] ?? "")")
        XCTAssertTrue(app.buttons["ad-break-short"].waitForExistence(timeout:10))
        XCTAssertEqual(puzzleValues(app)["adOffer"],"4|16")
        app.buttons["ad-break-short"].tap()
        // Google's full-screen ad covers the game, hiding its accessibility tree while it plays.
        let status=app.otherElements["puzzle-status"]
        let covered=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[covered],timeout:15),.completed,"The rewarded ad is presented")
        Thread.sleep(forTimeInterval:4)
        let showing=XCTAttachment(screenshot:XCUIScreen.main.screenshot());showing.name="Google sample rewarded ad";showing.lifetime = .keepAlways;add(showing)
        // Watch past the reward countdown, then close the ad.
        Thread.sleep(forTimeInterval:30)
        deadline=Date().addingTimeInterval(90)
        while !status.exists,Date()<deadline {
            let resume=app.buttons.matching(NSPredicate(format:"label CONTAINS[c] 'resume'")).firstMatch
            if resume.exists,resume.isHittable {resume.tap();Thread.sleep(forTimeInterval:10);continue}
            // Google's sample ad draws its close X at the top right beside "Reward granted"; its
            // accessible "Close Advertisement" button is a separate element that taps don't reach.
            app.coordinate(withNormalizedOffset:CGVector(dx:0.94,dy:0.099)).tap()
            Thread.sleep(forTimeInterval:2)
        }
        XCTAssertTrue(status.waitForExistence(timeout:5),"The ad closes")
        XCTAssertNotEqual(puzzleValues(app)["googleAd"],"showing")
        XCTAssertEqual(puzzleValues(app)["adBreak"],"0","A watched ad grants the batch instead of re-offering the break")
        XCTAssertEqual(puzzleValues(app)["houseAd"],"0","No house-ad fallback when Google filled the request")
        puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["freeRemaining"],"3","Four granted, one used by this puzzle")
        let after=XCTAttachment(screenshot:app.screenshot());after.name="Puzzle after the rewarded ad";after.lifetime = .keepAlways;add(after)
    }
    /// Taps Apple's tracking prompt or Google's IDFA explainer/consent form; returns what it tapped.
    @discardableResult @MainActor private func answerAdPrompts(_ app:XCUIApplication,_ springboard:XCUIApplication,allow:Bool=false) -> String? {
        for label in allow ? ["Allow"]:["Ask App Not to Track","Don’t Allow"] {let b=springboard.buttons[label];if b.exists {b.tap();return label}}
        // Google's IDFA explainer / consent form is a web view; its controls surface as buttons or links.
        for label in ["Continue","Consent","Do not consent"] {
            // UMP's web view reports its controls as not hittable, so tap their centre.
            // Google keeps a second, offscreen copy of its form, so pick the copy on screen.
            let screen=app.frame
            for query in [app.buttons.matching(identifier:label),app.links.matching(identifier:label)] {
                for b in query.allElementsBoundByIndex where !b.frame.isEmpty && screen.contains(CGPoint(x:b.frame.midX,y:b.frame.midY)) {
                    b.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap();return label
                }
            }
        }
        return nil
    }
    /// App Review (Guideline 2.1): Apple's tracking prompt appears on a fresh
    /// launch, before the ad SDK starts or any ad is requested, not at puzzle 5.
    @MainActor func testTrackingPromptAppearsAtFirstLaunch() throws {
        continueAfterFailure=false
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let app=XCUIApplication();app.resetAuthorizationStatus(for:.userTracking)
        app.launchArguments=["--uitesting","--real-ads","--board=6x6","--puzzle-mate=2","--reduced-motion"]
        app.launch()
        let allow=springboard.buttons["Ask App Not to Track"]
        var deadline=Date().addingTimeInterval(60),explainer=false
        while !allow.exists,Date()<deadline {if answerAdPrompts(app,springboard) == "Continue" {explainer=true};Thread.sleep(forTimeInterval:0.5)}
        XCTAssertTrue(allow.exists,"Apple's tracking prompt appears at launch")
        let prompt=XCTAttachment(screenshot:XCUIScreen.main.screenshot());prompt.name="Tracking prompt at first launch";prompt.lifetime = .keepAlways;add(prompt)
        XCTAssertEqual(puzzleValues(app)["tracking"],"0","Not determined until answered")
        XCTAssertEqual(puzzleValues(app)["googleAd"],"off","No ad SDK runs before the answer")
        allow.tap()
        deadline=Date().addingTimeInterval(10)
        while puzzleValues(app)["tracking"] == "0",Date()<deadline {Thread.sleep(forTimeInterval:0.3)}
        XCTAssertEqual(puzzleValues(app)["tracking"],"2","Declining is recorded")
        XCTAssertEqual(puzzleValues(app)["googleAd"],"off","The SDK still starts lazily, from the fifth puzzle")
        puzzleReady(app,timeout:90)
        XCTAssertTrue(app.buttons["square-a1"].exists,"Free play continues after declining")
        let after=XCTAttachment(screenshot:app.screenshot());after.name="Puzzle after the prompt (explainer: \(explainer))";after.lifetime = .keepAlways;add(after)
    }
    /// App Review evidence (Guideline 2.1), physical device only: resets only
    /// CloudChess's tracking permission, launches the installed build and answers Google's explainer (when served) and Apple's
    /// prompt, then leaves the player's board untouched. Xcode's screen
    /// recording of this test is the review video. Opt in with
    /// TEST_RUNNER_CC_REVIEW_RECORDING=1.
    @MainActor func testReviewRecordingTrackingPrompt() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CC_REVIEW_RECORDING"] == "1","Review recording runs only on request")
        continueAfterFailure=false
        let springboard=XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let app=XCUIApplication(bundleIdentifier:"com.maroon.CloudChess")
        app.resetAuthorizationStatus(for:.userTracking);app.terminate()
        // The Mac launches the installed build with devicectl: XCTest's own launch
        // fails on an iOS release newer than this Xcode's SDK.
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:120),"CloudChess launched")
        let decline=springboard.buttons["Ask App Not to Track"]
        let deadline=Date().addingTimeInterval(60)
        var explainer=false
        while !decline.exists,Date()<deadline {
            let screen=app.frame
            let shown=[app.buttons.matching(identifier:"Continue"),app.links.matching(identifier:"Continue")].contains {q in q.allElementsBoundByIndex.contains {!$0.frame.isEmpty && screen.contains(CGPoint(x:$0.frame.midX,y:$0.frame.midY))}}
            if shown,!explainer {explainer=true;Thread.sleep(forTimeInterval:3);answerAdPrompts(app,springboard)}
            Thread.sleep(forTimeInterval:0.4)
        }
        XCTAssertTrue(decline.exists,"Apple's tracking prompt appears at launch")
        Thread.sleep(forTimeInterval:4)
        decline.tap()
        Thread.sleep(forTimeInterval:7)
        XCTAssertEqual(app.state,.runningForeground,"Play continues after declining")
    }
    @MainActor func testOfflineFreePlayIsBlocked() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--monetization-testing","--offline","--reduced-motion"]
        app.launch()
        let message=app.staticTexts["offline-message"]
        XCTAssertTrue(message.waitForExistence(timeout:45))
        XCTAssertEqual(message.label,"While this app does run offline, we rely on ads to support the app. Please either subscribe or turn on data.")
        XCTAssertTrue(app.staticTexts["Hey!"].exists);XCTAssertFalse(app.buttons["square-a1"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Offline free play blocked";shot.lifetime = .keepAlways;add(shot)
        app.buttons["offline-retry"].tap();XCTAssertTrue(message.waitForExistence(timeout:5),"Still offline")
        app.buttons["offline-subscribe"].tap();XCTAssertTrue(app.descendants(matching:.any)["subscription-panel"].waitForExistence(timeout:10))
    }

    func testPrivacySupportAndLicensePanels() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--reduced-motion"]
        app.launch();puzzleReady(app)
        let before=puzzleValues(app)
        app.buttons["Settings"].tap();app.buttons["Privacy & support"].tap()
        XCTAssertFalse(app.buttons["square-a1"].exists)
        XCTAssertFalse(app.buttons["Close settings"].exists)
        app.buttons["legal-privacy"].tap()
        XCTAssertTrue(app.staticTexts["Your game stays on your device"].waitForExistence(timeout:3))
        XCTAssertTrue(app.buttons["legal-back"].isHittable)
        let privacy=XCTAttachment(screenshot:app.screenshot());privacy.name="Offline privacy policy";privacy.lifetime = .keepAlways;add(privacy)
        app.buttons["legal-back"].tap();app.buttons["legal-support"].tap()
        XCTAssertTrue(app.links["legal-email"].exists || app.buttons["legal-email"].exists)
        app.buttons["legal-back"].tap();app.buttons["legal-licenses"].tap()
        let license=app.buttons["legal-gpl"]
        for _ in 0..<8 {if license.isHittable {break};app.scrollViews.firstMatch.swipeUp()}
        XCTAssertTrue(license.isHittable);license.tap()
        XCTAssertTrue(app.buttons["Close gnu gpl v3"].isHittable)
        app.buttons["legal-back"].tap();app.buttons["Close open-source notices"].tap()
        XCTAssertTrue(app.buttons["square-a1"].exists)
        XCTAssertEqual(puzzleValues(app)["id"],before["id"])
        XCTAssertEqual(puzzleValues(app)["score"],before["score"])
        XCTAssertEqual(puzzleValues(app)["moves"],before["moves"])
    }
    func testLoadingSweepEvidence() throws {
        continueAfterFailure=false
        for kind in ["tactics","tenMoves","finish","opening"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=\(kind)","--reduced-motion"]
            app.launch();puzzleReady(app,timeout:90)
            let v=puzzleValues(app)
            print("SWEEP_LOADING mode=\(kind) workMs=\(v["generationWorkMs"] ?? "missing") fullMs=\(v["generationFullMs"] ?? "missing") id=\(v["id"] ?? "missing")")
            XCTAssertEqual(v["boardMatches"],"1")
            XCTAssertEqual(v["error"],"0")
            app.terminate()
        }
    }
    private func puzzleValues(_ app:XCUIApplication)->[String:String] {
        let value=app.otherElements["puzzle-status"].value as? String ?? ""
        return Dictionary(uniqueKeysWithValues:value.split(separator:",").map { part in
            let p=part.split(separator:":",maxSplits:1,omittingEmptySubsequences:false);return (String(p[0]),p.count>1 ? String(p[1]):"")
        })
    }
    private func puzzleReady(_ app:XCUIApplication,timeout:Double=40) {
        let status=app.otherElements["puzzle-status"]
        XCTAssertTrue(status.waitForExistence(timeout:10))
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","ready:1,","evaluating:0,"),object:status)
        let outcome=XCTWaiter.wait(for:[ready],timeout:timeout)
        XCTAssertEqual(outcome,.completed,"Puzzle readiness: \(status.value ?? "missing")")
        dismissInstructions(app)
    }
    private func dismissInstructions(_ app:XCUIApplication) {
        for _ in 0..<4 {let next=app.buttons["tutorial-next"];if next.exists {next.tap();Thread.sleep(forTimeInterval:0.35)} else {break}}
        let info=app.buttons["acknowledge-instructions"];if info.exists {info.tap()}
    }
    private func openCollection(_ app:XCUIApplication) {
        if !app.buttons["Dream collection"].exists {app.buttons["Settings"].tap()}
        app.buttons["Dream collection"].tap()
    }
    func testHandoffLatencyEvidence() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1"];app.launch();puzzleReady(app)
        let before=puzzleValues(app)["id"]
        puzzleMove(app,puzzleValues(app)["next"]!)
        let changed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@ AND NOT value CONTAINS %@","ready:1,","id:\(before!),"),object:app.otherElements["puzzle-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:40),.completed)
        let values=puzzleValues(app)
        print("HANDOFF_EVIDENCE \(values["lastJourneyMs"] ?? "missing")")
        dismissInstructions(app)
        XCTAssertEqual(values["boardMatches"],"1")
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Responsive original set and larger board";image.lifetime = .keepAlways;add(image)
    }
    private func puzzleMove(_ app:XCUIApplication,_ move:String,drag:Bool=false) {
        let from=app.buttons["square-"+String(move.prefix(2))],to=app.buttons["square-"+String(move.dropFirst(2).prefix(2))]
        if drag {from.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.2,thenDragTo:to.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)))}
        else {from.tap();to.tap()}
        if move.count==5 {
            let names:[Character:String]=["q":"Queen","r":"Rook","b":"Bishop","n":"Knight"]
            let button=app.buttons[names[move.last!]!];XCTAssertTrue(button.waitForExistence(timeout:5));button.tap()
        }
    }
    func testOriginalSetAndEdgeLayout() throws {
        continueAfterFailure=false
        for shape in ["8x8","4x6","6x4"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=\(shape)","--puzzle-mate=2","--piece-gallery","--reduced-motion"];app.launch();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["pieceTheme"],"0")
            XCTAssertFalse(app.buttons["Dream collection"].exists,"Collection belongs in Settings, not the bottom dock")
            XCTAssertGreaterThanOrEqual(app.staticTexts["live-score"].frame.height,25)
            XCTAssertGreaterThanOrEqual(app.otherElements["puzzle-hearts"].frame.height,15,"Accessibility reports the visible glyph bounds, not the 18pt font em size")
            for square in app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","square-")).allElementsBoundByIndex {
                XCTAssertTrue(app.frame.contains(square.frame),"Edge squares stay tappable")
            }
            let image=XCTAttachment(screenshot:app.screenshot());image.name="Original set \(shape)";image.lifetime = .keepAlways;add(image)
            app.terminate()
        }
    }
    func testTabletBoardResize() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=8x8","--puzzle-mate=2","--piece-gallery","--reduced-motion"];app.launch();puzzleReady(app)
        let initial=puzzleValues(app)
        for orientation in [UIDeviceOrientation.portrait,.landscapeLeft,.portrait] {
            XCUIDevice.shared.orientation=orientation
            let landscape=orientation == .landscapeLeft
            let resized=NSPredicate {_,_ in landscape ? app.frame.width>app.frame.height:app.frame.height>app.frame.width}
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:resized,object:nil)],timeout:5),.completed)
            let edge=app.buttons["square-a1"];XCTAssertTrue(edge.waitForExistence(timeout:5))
            for square in app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","square-")).allElementsBoundByIndex {
                XCTAssertTrue(app.frame.contains(square.frame),"Resizing must keep every square accessible")
            }
            XCTAssertEqual(puzzleValues(app)["id"],initial["id"])
            XCTAssertEqual(puzzleValues(app)["moves"],initial["moves"])
            let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot());image.name="Tablet board \(orientation.rawValue)";image.lifetime = .keepAlways;add(image)
        }
    }
    func testEvaluationBoardClearance() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--challenge-fixture=white","--reduced-motion"];app.launch();puzzleReady(app)
        let bar=app.otherElements["Position evaluation"].firstMatch
        XCTAssertTrue(bar.exists)
        for square in app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","square-")).allElementsBoundByIndex {
            XCTAssertLessThan(square.frame.maxY,bar.frame.minY,"Expanded board must remain above the evaluation panel")
        }
        let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot());image.name="Evaluation board clearance";image.lifetime = .keepAlways;add(image)
    }
    func testStoreLargeTextAndModalDismissal() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--reduced-motion","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"];app.launch();puzzleReady(app)
        app.buttons["Settings"].tap()
        let close=app.buttons["Close settings"]
        XCTAssertTrue(close.isHittable);XCTAssertTrue(app.frame.contains(close.frame))
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Largest text settings";image.lifetime = .keepAlways;add(image)
        close.tap();app.buttons["Skip puzzle"].tap()
        for name in ["confirm-action","cancel-action"] {
            XCTAssertTrue(app.buttons[name].isHittable);XCTAssertTrue(app.frame.contains(app.buttons[name].frame))
        }
        let warning=XCTAttachment(screenshot:app.screenshot());warning.name="Largest text confirmation";warning.lifetime = .keepAlways;add(warning)
        app.buttons["cancel-action"].tap()
        XCTAssertTrue(app.buttons["square-a1"].exists)
    }
    func testStoreMenusAndCustomConfirmations() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--score=1000000","--reduced-motion"];app.launch();puzzleReady(app)
        let before=puzzleValues(app)
        app.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["Debug menu"].exists);XCTAssertFalse(app.buttons["square-a1"].exists)
        XCTAssertTrue(app.buttons["Toggle sound"].exists);XCTAssertTrue(app.buttons["Close settings"].isHittable)
        let settings=XCTAttachment(screenshot:app.screenshot());settings.name="Store settings";settings.lifetime = .keepAlways;add(settings)
        XCTAssertFalse(app.buttons["Profile analysis"].exists,"Profile analysis is removed from the app (2.1)")
        app.buttons["Close settings"].tap()
        app.buttons["Skip puzzle"].tap()
        XCTAssertTrue(app.descendants(matching:.any)["confirmation-panel"].exists,"Use the authored CloudChess card; its modal accessibility trait may be reported as an Alert")
        XCTAssertFalse(app.buttons["square-a1"].exists)
        XCTAssertTrue(app.buttons["confirm-action"].isHittable);XCTAssertTrue(app.buttons["cancel-action"].isHittable)
        let warning=XCTAttachment(screenshot:app.screenshot());warning.name="Custom skip confirmation";warning.lifetime = .keepAlways;add(warning)
        app.buttons["cancel-action"].tap()
        XCTAssertEqual(puzzleValues(app)["score"],before["score"]);XCTAssertEqual(puzzleValues(app)["id"],before["id"])
        XCTAssertEqual(puzzleValues(app)["moves"],before["moves"])
    }
    func testKeyPieceHintAlwaysAvailableAndDiscountOnlyReward() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--score=1000000","--reduced-motion"];app.launch();puzzleReady(app)
        let initial=puzzleValues(app),reward=Double(initial["reward"]!)!
        app.buttons["Hint"].tap();XCTAssertTrue(app.staticTexts["Reveal the key piece?"].waitForExistence(timeout:5))
        XCTAssertTrue(app.otherElements["hint-cost"].exists || app.staticTexts["hint-cost"].exists,"The reward cut is drawn, not just described")
        let card=XCTAttachment(screenshot:app.screenshot());card.name="Hint cost graphic";card.lifetime = .keepAlways;add(card)
        app.buttons["cancel-action"].tap()
        XCTAssertEqual(puzzleValues(app)["hintDiscounts"],"0","Cancelling never charges")
        app.buttons["Hint"].tap();app.buttons["confirm-action"].tap()
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"value CONTAINS %@","hintPulse:1,"),evaluatedWith:status);waitForExpectations(timeout:20)
        var v=puzzleValues(app)
        XCTAssertEqual(v["score"],initial["score"]);XCTAssertEqual(v["moves"],"0");XCTAssertEqual(v["mistakes"],"0")
        XCTAssertEqual(v["hintDiscounts"],"1");XCTAssertEqual(Double(v["reward"]!)!,reward*0.9,accuracy:2)
        // The key piece pulses for about three seconds, then the board is plain again.
        expectation(for:NSPredicate(format:"value CONTAINS %@","hintPulse:0,"),evaluatedWith:status);waitForExpectations(timeout:6)
        XCTAssertTrue(app.buttons["Hint"].isEnabled,"The hint stays available")
        app.buttons["Hint"].tap()
        expectation(for:NSPredicate(format:"value CONTAINS %@","hintPulse:1,"),evaluatedWith:status);waitForExpectations(timeout:10)
        XCTAssertFalse(app.staticTexts["Reveal the key piece?"].exists,"Asking again at the same position needs no confirmation")
        v=puzzleValues(app);XCTAssertEqual(v["hintDiscounts"],"1","…and is free");XCTAssertEqual(Double(v["reward"]!)!,reward*0.9,accuracy:2)
        puzzleMove(app,initial["next"]!);puzzleReady(app)
        XCTAssertTrue(app.buttons["Hint"].isEnabled,"The next move earns a new hint")
        v=puzzleValues(app);XCTAssertEqual(v["hintDiscounts"],"1","Prior discounts survive a correct move")
    }
    func testUndoIsFreeAndRewindsOneTurn() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=3","--hold-completion","--reduced-motion"];app.launch();puzzleReady(app)
        let original=puzzleValues(app),value=pow(Double(original["itemRating"]!)!,1.5)
        XCTAssertFalse(app.buttons["Undo move"].isEnabled,"Nothing to undo yet")
        for _ in 0..<2 {puzzleMove(app,puzzleValues(app)["next"]!);puzzleReady(app)}
        XCTAssertEqual(puzzleValues(app)["moves"],"4")
        for index in 1...2 {
            app.buttons["Undo move"].tap();puzzleReady(app)
            XCTAssertFalse(app.descendants(matching:.any)["confirmation-panel"].exists,"Undo needs no confirmation")
            XCTAssertEqual(puzzleValues(app)["id"],original["id"])
            XCTAssertEqual(puzzleValues(app)["moves"],String(4-index*2))
            XCTAssertEqual(puzzleValues(app)["undos"],String(index))
            XCTAssertEqual(Double(puzzleValues(app)["reward"]!)!,value,accuracy:2,"Undo never lowers the reward")
            XCTAssertEqual(puzzleValues(app)["score"],"0")
        }
        XCTAssertFalse(app.buttons["Undo move"].isEnabled)
        for _ in 0..<3 {
            if puzzleValues(app)["completed"]=="1" {break}
            puzzleMove(app,puzzleValues(app)["next"]!)
            if puzzleValues(app)["completed"] != "1" {puzzleReady(app)}
        }
        XCTAssertEqual(puzzleValues(app)["completed"],"1")
        XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,value,accuracy:2,"Full reward after undoing")
        XCTAssertEqual(puzzleValues(app)["error"],"0")
    }
    func testCloudJourneyAndOptionalPreviousPuzzleReplay() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1"];app.launch();puzzleReady(app)
        puzzleMove(app,puzzleValues(app)["next"]!)
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"value CONTAINS %@","journey:1,"),evaluatedWith:status);waitForExpectations(timeout:10)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Through the clouds";shot.lifetime = .keepAlways;add(shot)
        XCTAssertFalse(app.buttons["Hint"].exists)
        for frame in 0..<2 {
            Thread.sleep(forTimeInterval:0.2)
            let image=XCTAttachment(screenshot:app.screenshot());image.name="Cloud handoff frame \(frame)";image.lifetime = .keepAlways;add(image)
        }
        puzzleReady(app)
        let current=puzzleValues(app)
        // 0.38 s veil close + 0.55 s cinematic window + 0.03 s settle + 0.4 s opening.
        XCTAssertGreaterThanOrEqual(Int(current["lastJourneyMs"]!)!,800)
        XCTAssertEqual(current["journeyFallbacks"],"0","Fast generation stays inside the cloud transition")
        XCTAssertLessThan(Int(current["lastJourneyMs"]!)!,2200)
        XCTAssertFalse(app.buttons["Watch the key moment"].exists,"The replay button was removed from the dock")
        XCTAssertEqual(puzzleValues(app)["boardMatches"],"1")
    }
    func testCloudJourneyLoadingFallback() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=5x5","--puzzle-mate=1","--journey-slow"];app.launch();puzzleReady(app)
        puzzleMove(app,puzzleValues(app)["next"]!)
        XCTAssertTrue(app.staticTexts["generation-message"].waitForExistence(timeout:12))
        XCTAssertEqual(puzzleValues(app)["journeyFallback"],"1")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Honest generation fallback after the journey";shot.lifetime = .keepAlways;add(shot)
        puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["journey"],"0");XCTAssertEqual(puzzleValues(app)["journeyFallbacks"],"1")
        XCTAssertEqual(puzzleValues(app)["boardMatches"],"1")
    }
    func testInstructionPopupBoundsAndBlockedBoard() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--challenge-fixture=white","--reduced-motion"];app.launch()
        let button=app.buttons["acknowledge-instructions"]
        XCTAssertTrue(button.waitForExistence(timeout:90))
        let panel=app.descendants(matching:.any)["instruction-panel"]
        XCTAssertGreaterThan(panel.frame.minX,8);XCTAssertGreaterThan(panel.frame.minY,30)
        XCTAssertLessThan(panel.frame.height,app.frame.height*0.86)
        XCTAssertLessThan(app.staticTexts["first-instruction-notice"].frame.maxY,button.frame.minY,"Default instructions fit above the pinned button")
        XCTAssertEqual(puzzleValues(app)["revealed"],"1")
        XCTAssertFalse(app.buttons["square-a1"].exists)
        let initial=puzzleValues(app)["id"]
        app.coordinate(withNormalizedOffset:CGVector(dx:0.03,dy:0.04)).tap()
        XCTAssertTrue(button.exists,"Backdrop absorbs taps")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Floating instructions";shot.lifetime = .keepAlways;add(shot)
        button.tap();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["id"],initial)
        XCTAssertTrue(app.buttons["square-a1"].exists)
    }
    func testEveryFreePlayMoveHasQualityFeedback() throws {
        continueAfterFailure=false
        for mode in ["finish","tenMoves","blunderPunish"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=\(mode)","--challenge-fixture=white","--blunder-seed=12","--evaluation-audit"]
            app.launch();puzzleReady(app,timeout:120)
            let move=puzzleValues(app)["next"]!
            puzzleMove(app,move,drag:true)
            let badge=app.otherElements["move-quality"]
            XCTAssertTrue(badge.waitForExistence(timeout:3))
            XCTAssertTrue((badge.value as? String ?? "").contains("pending:1"),"Feedback starts before an uncached search finishes")
            XCTAssertEqual(puzzleValues(app)["moves"],"1","Piece is placed before grading")
            XCTAssertEqual(puzzleValues(app)["gradeSquare"],String(move.dropFirst(2).prefix(2)))
            expectation(for:NSPredicate(format:"value CONTAINS %@ AND NOT (value CONTAINS %@)","visible:1,","quality:pending,"),evaluatedWith:badge);waitForExpectations(timeout:30)
            XCTAssertEqual(puzzleValues(app)["gradeEvents"],"2","One pending badge becomes one final verdict")
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="\(mode) move quality above the piece";shot.lifetime = .keepAlways;add(shot)
            expectation(for:NSPredicate(format:"value CONTAINS %@","visible:0,"),evaluatedWith:badge);waitForExpectations(timeout:6)
            puzzleReady(app,timeout:120);XCTAssertEqual(puzzleValues(app)["error"],"0")
            app.terminate()
        }
    }
    func testPreparedFreePlayGradeAppearsWithoutPending() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--challenge-fixture=white","--turn-prefetch-audit","--reduced-motion"]
        app.launch();puzzleReady(app,timeout:120)
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"NOT (value CONTAINS %@)","preparedMoves:0,"),evaluatedWith:status);waitForExpectations(timeout:90)
        let move=puzzleValues(app)["next"]!;puzzleMove(app,move)
        puzzleReady(app,timeout:120)
        XCTAssertGreaterThan(Int(puzzleValues(app)["preparedMoveUsed"]!)!,0)
        XCTAssertEqual(puzzleValues(app)["gradeEvents"],"1","A prepared move immediately shows its final symbol")
        XCTAssertNotEqual(puzzleValues(app)["moveGrade"],"pending")
    }
    func testScoreOutcomeFeedback() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--hold-completion","--score=1000000"];app.launch();puzzleReady(app)
        let initial=puzzleValues(app),winning=Set(initial["winning"]!.split(separator:"|"))
        XCTAssertEqual(initial["scoreEvents"],"0","Loading a saved score is not an award")
        let bad=initial["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!
        puzzleMove(app,String(bad))
        let red=XCTAttachment(screenshot:app.screenshot());red.name="Red mistake feedback";red.lifetime = .keepAlways;add(red)
        puzzleReady(app)
        let mistake=puzzleValues(app)
        XCTAssertEqual(mistake["scoreEvents"],"1");XCTAssertEqual(mistake["scoreDirection"],"-1")
        XCTAssertEqual(mistake["mistakeFeedback"],"1");XCTAssertEqual(mistake["outcomeHaptics"],"1")
        XCTAssertLessThan(Int(mistake["score"]!)!,1_000_000)
        puzzleMove(app,puzzleValues(app)["next"]!)
        let green=XCTAttachment(screenshot:app.screenshot());green.name="Green score award";green.lifetime = .keepAlways;add(green)
        expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:40)
        let won=puzzleValues(app)
        XCTAssertEqual(won["scoreEvents"],"2");XCTAssertEqual(won["scoreDirection"],"1")
        XCTAssertEqual(won["outcomeHaptics"],"2");XCTAssertEqual(won["evaluating"],"0")
        XCTAssertGreaterThan(Int(won["score"]!)!,Int(mistake["score"]!)!)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Success score and celebration";shot.lifetime = .keepAlways;add(shot)
    }
    func testResponsiveEvaluationFeedback() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--challenge-fixture=white","--evaluation-audit","--score=1000000"];app.launch();puzzleReady(app,timeout:90)
        puzzleMove(app,"g6g4")
        XCTAssertTrue(app.otherElements["engine-thinking"].waitForExistence(timeout:5))
        let pending=puzzleValues(app)
        XCTAssertEqual(pending["moves"],"1","The legal move is visible before the long grading search")
        XCTAssertEqual(pending["revealed"],"1");XCTAssertEqual(pending["ready"],"0")
        XCTAssertFalse(app.buttons["Hint"].isEnabled);XCTAssertFalse(app.buttons["Undo move"].isEnabled)
        XCTAssertFalse(app.staticTexts["evaluation-verdict"].exists,"Do not announce a stale verdict")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Visible board while engine evaluates";shot.lifetime = .keepAlways;add(shot)
        puzzleReady(app,timeout:120)
        XCTAssertEqual(puzzleValues(app)["moves"],"2");XCTAssertEqual(puzzleValues(app)["score"],"1000000")
        XCTAssertEqual(puzzleValues(app)["evaluating"],"0")
        XCTAssertFalse(app.otherElements["engine-thinking"].exists)
        XCTAssertTrue(app.staticTexts["evaluation-verdict"].exists)
    }
    func testFiniteDropBeforeAnalysis() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=personal","--challenge-fixture=white","--evaluation-audit","--score=1000000"];app.launch();puzzleReady(app,timeout:90)
        puzzleMove(app,"g6g8",drag:true)
        XCTAssertTrue(app.otherElements["engine-thinking"].waitForExistence(timeout:5))
        let pending=puzzleValues(app)
        XCTAssertEqual(pending["pendingMove"],"g6g8")
        XCTAssertEqual(pending["moves"],"0","An ungraded finite move is not persisted")
        XCTAssertTrue(pending["visibleSquares"]!.split(separator:"|").contains("g8"))
        XCTAssertFalse(pending["visibleSquares"]!.split(separator:"|").contains("g6"))
        XCTAssertEqual(pending["score"],"1000000");XCTAssertEqual(pending["hearts"],"3")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Dropped piece visible before grading";shot.lifetime = .keepAlways;add(shot)
        puzzleReady(app,timeout:120)
        let rejected=puzzleValues(app)
        XCTAssertEqual(rejected["pendingMove"],"");XCTAssertEqual(rejected["moves"],"0");XCTAssertEqual(rejected["hearts"],"2")
        XCTAssertTrue(rejected["visibleSquares"]!.split(separator:"|").contains("g6"))
        XCTAssertFalse(rejected["visibleSquares"]!.split(separator:"|").contains("g8"))
    }
    func testPersonalMistakeFeedback() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=personal","--challenge-fixture=white","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app,timeout:90)
        puzzleMove(app,"g6g8");puzzleReady(app,timeout:90)
        let result=puzzleValues(app)
        XCTAssertEqual(result["moves"],"0");XCTAssertEqual(result["hearts"],"2")
        XCTAssertEqual(result["mistakeFeedback"],"1");XCTAssertEqual(result["scoreEvents"],"1")
        XCTAssertEqual(result["outcomeHaptics"],"1");XCTAssertEqual(result["scoreDirection"],"-1")
        XCTAssertEqual(result["evaluating"],"0")
    }
    func testInfoButtonEntireTouchTarget() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves"];app.launch();puzzleReady(app)
        let original=puzzleValues(app)
        for point in [CGVector(dx:0.15,dy:0.15),CGVector(dx:0.85,dy:0.85),CGVector(dx:0.5,dy:0.5)] {
            let info=app.buttons["Challenge information"]
            XCTAssertTrue(info.isEnabled);XCTAssertGreaterThanOrEqual(info.frame.width,44);XCTAssertGreaterThanOrEqual(info.frame.height,44)
            info.coordinate(withNormalizedOffset:point).tap()
            XCTAssertTrue(app.descendants(matching:.any)["instruction-panel"].waitForExistence(timeout:3),"The entire info button must respond, including its padded corners")
            XCTAssertTrue(app.staticTexts["challenge-explanation"].exists)
            dismissInstructions(app);puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["id"],original["id"])
            XCTAssertEqual(puzzleValues(app)["moves"],original["moves"])
            XCTAssertEqual(puzzleValues(app)["score"],original["score"])
        }
    }
    func testAutomaticMenuAndSamePuzzleInfo() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=3","--reduced-motion"];app.launch();puzzleReady(app)
        puzzleMove(app,puzzleValues(app)["next"]!);puzzleReady(app)
        let original=puzzleValues(app)
        XCTAssertEqual(original["moves"],"2")
        app.buttons["Challenge information"].tap()
        XCTAssertTrue(app.staticTexts["challenge-explanation"].waitForExistence(timeout:5))
        XCTAssertFalse(app.alerts["Read the instructions again?"].exists)
        dismissInstructions(app);puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["id"],original["id"])
        XCTAssertEqual(puzzleValues(app)["moves"],original["moves"])
        app.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["Challenges"].exists);XCTAssertFalse(app.buttons["Board size"].exists);XCTAssertFalse(app.buttons["Board style"].exists)
        XCTAssertFalse(app.buttons["Debug menu"].exists)
    }
    func testCollectionEquipPreservesProgress() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--collection-fixture","--reset-fixture","--reduced-motion"];app.launch();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["profileSaved"],"1");XCTAssertEqual(puzzleValues(app)["profileFile"],"1")
        openCollection(app)
        XCTAssertTrue(app.buttons["collection-board-1"].waitForExistence(timeout:10))
        app.buttons["collection-board-3"].tap();XCTAssertFalse(app.buttons["equip-collection"].isEnabled)
        let partial=XCTAttachment(screenshot:app.screenshot());partial.name="Two of eight visible-area tile reveal";partial.lifetime = .keepAlways;add(partial)
        app.buttons["Back to collection"].tap()
        app.buttons["collection-board-2"].tap();XCTAssertFalse(app.buttons["equip-collection"].isEnabled)
        app.buttons["Back to collection"].tap()
        app.buttons["collection-board-1"].tap()
        XCTAssertTrue(app.buttons["accept-skin"].waitForExistence(timeout:5))
        XCTAssertFalse(app.descendants(matching:.any)["collection-gallery"].exists)
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"0","Preview must not persist before acceptance")
        app.buttons["revert-skin"].tap()
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"0")
        openCollection(app);app.buttons["collection-board-1"].tap();app.buttons["accept-skin"].tap()
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"1")
        openCollection(app);app.buttons["Chess sets"].tap()
        app.buttons["collection-pieces-2"].tap();app.buttons["accept-skin"].tap()
        XCTAssertEqual(puzzleValues(app)["pieceTheme"],"2")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Equipped Aurora board and Observatory pieces";shot.lifetime = .keepAlways;add(shot)
        app.buttons["Settings"].tap();XCTAssertFalse(app.buttons["Debug menu"].exists)
        XCTAssertEqual(puzzleValues(app)["profileSaved"],"1");XCTAssertEqual(puzzleValues(app)["profileFile"],"1")
        app.buttons["Close settings"].tap()

    }
    func testLongPuzzleRewardsInInstructions() throws {
        continueAfterFailure=false
        for (kind,multiplier) in [("finish",3.0),("tenMoves",2.5)] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=\(kind)","--challenge-fixture=white","--hold-completion","--reduced-motion"];app.launch()
            XCTAssertTrue(app.staticTexts["long-puzzle-reward"].waitForExistence(timeout:40))
            XCTAssertTrue(app.staticTexts["long-puzzle-reward"].label.contains(multiplier==3 ? "3×":"2.5×"))
            dismissInstructions(app);puzzleReady(app)
            let initial=puzzleValues(app),value=pow(Double(initial["itemRating"]!)!,1.5)*multiplier
            puzzleMove(app,initial["next"]!)
            expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:30)
            XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,value,accuracy:1)
            app.terminate()
        }
    }
    func testSmartShuffleAcrossSkipsAndRelaunch() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--automatic-mix","--reduced-motion"];app.launch()
        var ids:[String]=[],kinds:[String]=[]
        for index in 0..<5 {
            puzzleReady(app,timeout:150)
            let values=puzzleValues(app),id=values["id"]!,kind=values["instructionType"]!
            XCTAssertFalse(ids.suffix(3).contains(id),"No puzzle within last three")
            XCTAssertNotEqual(kinds.last,kind,"No adjacent mode repeat")
            ids.append(id);kinds.append(kind)
            if index==2 {
                app.terminate();app.launchArguments=["--uitesting","--preserve-coach","--automatic-mix","--reduced-motion"];app.launch()
                // Returning intentionally supplies a fresh puzzle, using saved history.
            } else if index<4 {
                app.buttons["Skip puzzle"].tap();app.buttons["confirm-action"].tap()
            }
        }
        XCTAssertEqual(puzzleValues(app)["error"],"0")
    }
    func testRewardDoorsMilestoneAndPersistence() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--reward-soon","--board=6x6","--puzzle-mate=1"];app.launch();puzzleReady(app)
        puzzleMove(app,puzzleValues(app)["next"]!)
        XCTAssertTrue(app.buttons["reward-door-0"].waitForExistence(timeout:25))
        XCTAssertEqual(puzzleValues(app)["contents"],"9")
        XCTAssertEqual(puzzleValues(app)["rewardOwned"],"0")
        XCTAssertEqual(app.images.matching(NSPredicate(format:"label CONTAINS %@","shards")).count,0,"Closed doors must not reveal prize identities through accessibility")
        XCTAssertFalse(app.buttons["square-a1"].exists)
        let initial=XCTAttachment(screenshot:app.screenshot());initial.name="Nine cloud doors";initial.lifetime = .keepAlways;add(initial)
        app.buttons["reward-door-0"].tap()
        XCTAssertEqual(puzzleValues(app)["rewardPicks"],"1")
        XCTAssertEqual(puzzleValues(app)["rewardOwned"],"1")
        XCTAssertFalse(app.buttons["claim-reward"].exists)
        XCTAssertEqual(app.buttons["reward-door-1"].value as? String,"Closed")
        let selectedLabel=app.buttons["reward-door-0"].label
        app.terminate();app.launchArguments=["--uitesting","--preserve-coach"];app.launch()
        XCTAssertTrue(app.buttons["reward-door-1"].waitForExistence(timeout:15))
        XCTAssertEqual(app.buttons["reward-door-0"].label,selectedLabel)
        XCTAssertEqual(puzzleValues(app)["rewardChosen"],"0")
        XCTAssertEqual(puzzleValues(app)["rewardOwned"],"1")
        app.buttons["reward-door-4"].tap()
        XCTAssertTrue(app.buttons["claim-reward"].waitForExistence(timeout:8))
        XCTAssertEqual(puzzleValues(app)["rewardPicks"],"2")
        XCTAssertEqual(puzzleValues(app)["rewardOwned"],"2")
        XCTAssertEqual(puzzleValues(app)["rewardChosen"],"0|4")
        for (rarity,count) in [("Common ",6),("Rare ",2),("Legendary ",1)] {
            XCTAssertEqual(app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@",rarity)).count,count)
        }
        for i in 0..<9 {
            XCTAssertFalse(app.buttons["reward-door-\(i)"].isEnabled)
            XCTAssertEqual(app.buttons["reward-door-\(i)"].value as? String,[0,4].contains(i) ? "Collected":"Revealed, not collected")
        }
        let reveal=XCTAttachment(screenshot:app.screenshot());reveal.name="Two collected; seven revealed";reveal.lifetime = .keepAlways;add(reveal)
        app.terminate();app.launchArguments=["--uitesting","--preserve-coach"];app.launch()
        XCTAssertTrue(app.buttons["claim-reward"].waitForExistence(timeout:15))
        XCTAssertEqual(puzzleValues(app)["rewardOwned"],"2")
        app.buttons["claim-reward"].tap();puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["rewardBoard"],"0")
        XCTAssertEqual(puzzleValues(app)["error"],"0")
    }
    func testChallengeInstructionsScoreAndRetry() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--reduced-motion","--score=100000"];app.launch()
        XCTAssertTrue(app.staticTexts["challenge-explanation"].waitForExistence(timeout:40))
        XCTAssertTrue(app.staticTexts["first-instruction-notice"].exists)
        XCTAssertEqual(puzzleValues(app)["revealed"],"1","The board remains behind the popup")
        XCTAssertFalse(app.buttons["square-a1"].exists,"Modal blocks board accessibility and input")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Retry reward")).firstMatch.exists)
        let paused=puzzleValues(app)["score"]
        Thread.sleep(forTimeInterval:2);XCTAssertEqual(puzzleValues(app)["score"],paused)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Instructions popup over the board";shot.lifetime = .keepAlways;add(shot)
        dismissInstructions(app);puzzleReady(app)
        let initial=puzzleValues(app)
        Thread.sleep(forTimeInterval:2);XCTAssertEqual(puzzleValues(app)["score"],initial["score"])
        app.buttons["Challenge information"].tap()
        XCTAssertFalse(app.alerts["Read the instructions again?"].exists)
        XCTAssertTrue(app.staticTexts["challenge-explanation"].waitForExistence(timeout:5))
        XCTAssertFalse(app.staticTexts["first-instruction-notice"].exists)
        let reread=puzzleValues(app)["score"]
        Thread.sleep(forTimeInterval:2);XCTAssertEqual(puzzleValues(app)["score"],reread)
        dismissInstructions(app);puzzleReady(app)
        let fresh=puzzleValues(app)
        XCTAssertEqual(fresh["id"],initial["id"],"Rereading keeps the current puzzle")
        XCTAssertEqual(fresh["instructionType"],initial["instructionType"])
        XCTAssertFalse(app.descendants(matching:.any)["instruction-panel"].exists,"Only one automatic panel per type")
        XCTAssertEqual(fresh["completed"],"0","Reading is not a failed chess attempt")
        XCTAssertEqual(fresh["error"],"0")
    }
    func testScorePausesAwayAndResumesAdmittedPuzzle() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--reduced-motion","--score=100000"];app.launch();puzzleReady(app)
        let old=puzzleValues(app)
        let away=puzzleValues(app)["score"]
        XCUIDevice.shared.press(.home);Thread.sleep(forTimeInterval:3);app.activate();puzzleReady(app)
        XCTAssertFalse(app.buttons["continue-session"].exists,"Returning resumes the board directly")
        XCTAssertFalse(app.descendants(matching:.any)["return-panel"].exists)
        let score=puzzleValues(app)["score"];XCTAssertEqual(score,away)
        Thread.sleep(forTimeInterval:3);XCTAssertEqual(puzzleValues(app)["score"],score)
        XCTAssertEqual(puzzleValues(app)["revealed"],"1")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Return resumes the board";shot.lifetime = .keepAlways;add(shot)
        let next=puzzleValues(app)
        XCTAssertEqual(next["id"],old["id"]);XCTAssertEqual(next["instructionType"],old["instructionType"])
        XCTAssertFalse(app.descendants(matching:.any)["instruction-panel"].exists)
        XCTAssertEqual(next["score"],score)
        XCTAssertEqual(next["completed"],"0")
        app.terminate();app.launchArguments=["--uitesting","--preserve-coach","--reduced-motion"];app.launch();puzzleReady(app)
        XCTAssertFalse(app.buttons["continue-session"].exists,"A relaunch resumes the board directly")
        let restored=puzzleValues(app)["score"];XCTAssertEqual(restored,score)
        XCTAssertEqual(puzzleValues(app)["id"],next["id"])
        XCTAssertEqual(puzzleValues(app)["error"],"0")
    }
    func testPuzzleScopedHeartsAndPenalties() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app)
        func finalMistake() {
            let v=puzzleValues(app),winning=Set(v["winning"]!.split(separator:"|"))
            let bad=v["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!
            puzzleMove(app,String(bad));puzzleReady(app)
        }
        let original=puzzleValues(app),value=pow(Double(original["itemRating"]!)!,1.5)
        XCTAssertEqual(original["retired"],"0")
        puzzleMove(app,original["next"]!);puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["hearts"],"3","A move inside the budget never costs a heart")
        finalMistake();XCTAssertEqual(puzzleValues(app)["hearts"],"2")
        XCTAssertEqual(puzzleValues(app)["moves"],"2","Only the missed final try is taken back")
        Thread.sleep(forTimeInterval:2)
        XCTAssertEqual(puzzleValues(app)["undoTipEvents"],"0","The mate is still available: no undo tip");XCTAssertFalse(app.buttons["undo-tip"].exists)
        XCTAssertEqual(puzzleValues(app)["mistakeFeedback"],"1");XCTAssertEqual(puzzleValues(app)["scoreDirection"],"-1")
        XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,1_000_000-value*0.25,accuracy:2)
        app.buttons["Undo move"].tap();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["moves"],"0")
        XCTAssertEqual(puzzleValues(app)["hearts"],"2","Attempts belong to this puzzle; undo does not refill")
        puzzleMove(app,puzzleValues(app)["next"]!);puzzleReady(app)
        finalMistake();XCTAssertEqual(puzzleValues(app)["hearts"],"1")
        // The failed position stays visible before the failure card (1.2 s under reduced motion).
        let hold=failureHold(app) {let v=puzzleValues(app),winning=Set(v["winning"]!.split(separator:"|"));puzzleMove(app,String(v["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!))}
        XCTAssertGreaterThanOrEqual(hold,1.0,"Third lost heart rests on the failed position before the card")
        XCTAssertTrue(app.buttons["failure-next"].waitForExistence(timeout:5))
        app.buttons["failure-next"].tap();puzzleReady(app);let after=puzzleValues(app)
        XCTAssertNotEqual(after["id"],original["id"]);XCTAssertEqual(after["hearts"],"3")
        XCTAssertEqual(after["retired"],"1","The failed puzzle is retired, never repeated")
        XCTAssertEqual(Double(after["score"]!)!,max(0,1_000_000-value*2.5),accuracy:2)
        XCTAssertEqual(after["mistakeFeedback"],"3");XCTAssertEqual(after["scoreEvents"],"3")
        XCTAssertEqual(after["best"],"1000000","A failed puzzle never resets the lifetime high")
        XCTAssertTrue(app.otherElements["all-time-high"].exists)
        app.buttons["Skip puzzle"].tap();XCTAssertTrue(app.staticTexts["Skip this puzzle?"].waitForExistence(timeout:5))
        app.buttons["cancel-action"].tap();XCTAssertEqual(puzzleValues(app)["id"],after["id"])
        let skip=pow(Double(after["itemRating"]!)!,1.5)/2
        app.buttons["Skip puzzle"].tap();app.buttons["confirm-action"].tap();puzzleReady(app)
        XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,max(0,Double(after["score"]!)!-skip),accuracy:2)
        XCTAssertEqual(puzzleValues(app)["error"],"0")
        XCTAssertEqual(puzzleValues(app)["retired"],"2","A skip retires its puzzle too")
        XCTAssertEqual(puzzleValues(app)["scoreEvents"],"4");XCTAssertEqual(puzzleValues(app)["outcomeHaptics"],"4")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Per-puzzle hearts and lifetime crown";shot.lifetime = .keepAlways;add(shot)
    }
    /// Mate in x plays on after a wrong move; the misstep hint and undo recover it.
    func testMoveBudgetPlayOnHintAndUndo() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--reduced-motion","--score=100000"];app.launch();puzzleReady(app)
        XCTAssertTrue(app.staticTexts["Mate in 2"].exists)
        XCTAssertEqual(app.otherElements["moves-used"].value as? String,"0 of 2")
        let start=puzzleValues(app),winning=Set(start["winning"]!.split(separator:"|"))
        let wrong=String(start["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!)
        puzzleMove(app,wrong);puzzleReady(app)
        var v=puzzleValues(app)
        XCTAssertEqual(v["moves"],"2","A wrong move is answered, not rejected")
        XCTAssertEqual(v["hearts"],"3");XCTAssertEqual(v["mistakeFeedback"],"0");XCTAssertEqual(v["offTrack"],"0")
        XCTAssertEqual(v["score"],start["score"]);XCTAssertEqual(app.otherElements["moves-used"].value as? String,"1 of 2")
        app.buttons["Hint"].tap();XCTAssertTrue(app.staticTexts["No winning moves in this position!"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Maybe undo a few moves..."].exists)
        let card=XCTAttachment(screenshot:app.screenshot());card.name="No winning moves";card.lifetime = .keepAlways;add(card)
        app.buttons["no-win-close"].tap();puzzleReady(app)
        v=puzzleValues(app)
        XCTAssertEqual(v["hintStage"],"0","The no-win notice is free");XCTAssertEqual(v["hints"],"0");XCTAssertEqual(v["score"],start["score"]);XCTAssertEqual(v["noWin"],"0")
        let final=String(v["legal"]!.split(separator:"|").first{$0.count==4}!)
        puzzleMove(app,final);puzzleReady(app)
        v=puzzleValues(app)
        XCTAssertEqual(v["hearts"],"2","Using both moves without mate costs a heart");XCTAssertEqual(v["moves"],"2");XCTAssertEqual(v["mistakeFeedback"],"1")
        let tip=app.buttons["undo-tip"];XCTAssertTrue(tip.waitForExistence(timeout:10),"No mate remains here: suggest undoing earlier moves")
        XCTAssertEqual(tip.label,"Hint: you may want to undo some previous moves!")
        let toast=XCTAttachment(screenshot:app.screenshot());toast.name="Undo tip";toast.lifetime = .keepAlways;add(toast)
        XCTAssertEqual(puzzleValues(app)["undoTipEvents"],"1");XCTAssertEqual(puzzleValues(app)["undoTipsShown"],"1")
        app.buttons["undo-tip"].tap()
        // The no-win card offers the undo itself.
        app.buttons["Hint"].tap();XCTAssertTrue(app.buttons["no-win-undo"].waitForExistence(timeout:5))
        app.buttons["no-win-undo"].tap();puzzleReady(app)
        v=puzzleValues(app)
        XCTAssertEqual(v["moves"],"0");XCTAssertEqual(v["offTrack"],"-1");XCTAssertEqual(v["undos"],"1");XCTAssertEqual(v["hearts"],"2")
        XCTAssertFalse(app.buttons["undo-tip"].exists,"Undo dismisses the tip")
        app.buttons["Hint"].tap();XCTAssertTrue(app.staticTexts["Reveal the key piece?"].waitForExistence(timeout:5),"On the winning line the ordinary hint returns")
        app.buttons["cancel-action"].tap();puzzleReady(app)
        puzzleMove(app,v["next"]!);puzzleReady(app);puzzleMove(app,puzzleValues(app)["next"]!)
        expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:40)
    }
    /// Improve in x: the horizon reply decides; no net gain costs a heart and rewinds one turn.
    func testImproveInXHorizonHeartAndMaterialBar() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--tutorial-fixture=ddec583138a388ce3824010e","--reduced-motion","--score=100000"];app.launch();puzzleReady(app)
        XCTAssertTrue(app.staticTexts["Improve position in 2"].exists)
        let bar=app.otherElements["material-bar"];XCTAssertTrue(bar.exists)
        XCTAssertEqual(bar.value as? String,"Level with the start")
        XCTAssertEqual(puzzleValues(app)["startMaterial"],"-1")
        puzzleMove(app,"b3c3");puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["moves"],"2");XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        puzzleMove(app,"c3d3");puzzleReady(app)
        let v=puzzleValues(app)
        XCTAssertEqual(v["hearts"],"2","Finishing below the start costs a heart");XCTAssertEqual(v["moves"],"2","The horizon turn is taken back for free")
        XCTAssertEqual(v["undos"],"0");XCTAssertEqual(v["mistakeFeedback"],"1")
        XCTAssertTrue(app.buttons["undo-tip"].waitForExistence(timeout:10),"After Kc3 Rc6+ no net gain is forced: suggest undo")
        app.buttons["Undo move"].tap();puzzleReady(app)
        puzzleMove(app,"c2b4");puzzleReady(app);puzzleMove(app,"b4a6")
        expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:40)
    }
    /// Seconds between the first `phase:failed,` observation and the failure card.
    private func failureHold(_ app:XCUIApplication,after action:()->Void)->Double {
        let status=app.otherElements["puzzle-status"]
        action()
        let deadline=Date().addingTimeInterval(60);var failedAt:Date?
        while Date()<deadline {
            let value=status.value as? String ?? ""
            if failedAt==nil,value.contains("phase:failed,") {failedAt=Date()}
            if let failedAt,value.contains("failureCard:1,") {return Date().timeIntervalSince(failedAt)}
        }
        XCTFail("Third mistake never reached the failed phase and its card: \(status.value ?? "missing")");return 0
    }
    func testFailureHoldWithMotion() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--score=1000000"];app.launch();puzzleReady(app)
        func bad()->String {let v=puzzleValues(app),winning=Set(v["winning"]!.split(separator:"|"));return String(v["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!)}
        XCTAssertEqual(puzzleValues(app)["moves"],"0")
        for _ in 0..<2 {puzzleMove(app,bad());puzzleReady(app)}
        XCTAssertEqual(puzzleValues(app)["hearts"],"1")
        let hold=failureHold(app) {puzzleMove(app,bad())}
        XCTAssertGreaterThanOrEqual(hold,1.5,"Third mistake rests 1.8 s with motion on")
        app.buttons["failure-next"].tap();puzzleReady(app);let after=puzzleValues(app)
        XCTAssertEqual(after["hearts"],"3");XCTAssertEqual(after["retired"],"1")
        XCTAssertGreaterThanOrEqual(Int(after["lastJourneyMs"]!)!,800);XCTAssertLessThan(Int(after["lastJourneyMs"]!)!,2200)
    }
    /// Out of hearts: the card offers a manual solution replay, a guided solve with arrows, or the next puzzle.
    func testFailureCardSolutionGuidedSolveAndNext() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app)
        let status=app.otherElements["puzzle-status"],original=puzzleValues(app)
        func finalMistake() {
            let v=puzzleValues(app),winning=Set(v["winning"]!.split(separator:"|"))
            puzzleMove(app,String(v["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!))
        }
        func wait(_ format:String,_ args:[Any],_ timeout:Double=20) {
            let e=XCTNSPredicateExpectation(predicate:NSPredicate(format:format,argumentArray:args),object:status)
            XCTAssertEqual(XCTWaiter.wait(for:[e],timeout:timeout),.completed,"\(format) \(args): \(status.value ?? "missing")")
        }
        puzzleMove(app,original["next"]!);puzzleReady(app)
        finalMistake();puzzleReady(app);finalMistake();puzzleReady(app);finalMistake()
        let card=app.descendants(matching:.any)["failure-panel"]
        XCTAssertTrue(card.waitForExistence(timeout:10),"Losing every heart offers the choices")
        XCTAssertTrue(app.staticTexts["Out of hearts"].exists)
        for id in ["failure-solution","failure-guided","failure-next"] {XCTAssertTrue(app.buttons[id].isHittable,id)}
        XCTAssertFalse(app.buttons["square-a1"].exists,"The card blocks the board")
        let failed=puzzleValues(app);XCTAssertEqual(failed["retired"],"1");XCTAssertEqual(failed["phase"],"failed")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Out of hearts";shot.lifetime = .keepAlways;add(shot)
        // a) The whole solution, stepped by hand.
        app.buttons["failure-solution"].tap()
        XCTAssertTrue(app.buttons["replay-next"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["replay-play"].exists,"The solution steps only by hand")
        var v=puzzleValues(app);XCTAssertEqual(v["replay"],"1");XCTAssertEqual(v["replayIndex"],"0");XCTAssertEqual(v["replayCount"],"4","Start plus the three solution plies")
        app.buttons["replay-next"].tap();app.buttons["replay-next"].tap();XCTAssertEqual(puzzleValues(app)["replayIndex"],"2")
        app.buttons["replay-back"].tap();XCTAssertEqual(puzzleValues(app)["replayIndex"],"1")
        app.buttons["replay-next"].tap();app.buttons["replay-next"].tap();XCTAssertEqual(puzzleValues(app)["replayIndex"],"3")
        XCTAssertFalse(app.buttons["replay-next"].isEnabled)
        let replay=XCTAttachment(screenshot:app.screenshot());replay.name="Solution replay";replay.lifetime = .keepAlways;add(replay)
        app.buttons["close-replay"].tap()
        XCTAssertTrue(card.waitForExistence(timeout:5),"Closing the replay returns to the choices");XCTAssertEqual(puzzleValues(app)["replay"],"0")
        // b) Back to the start; the arrowed moves solve it; the defense follows the solution.
        app.buttons["failure-guided"].tap()
        wait("value CONTAINS %@ AND value CONTAINS %@",["guided:1,","ready:1,"])
        v=puzzleValues(app);XCTAssertEqual(v["moves"],"0");XCTAssertEqual(v["arrow"]!.count,4,"An arrow shows the first move")
        XCTAssertFalse(app.buttons["Undo move"].isEnabled);XCTAssertFalse(app.buttons["Hint"].isEnabled)
        let arrows=XCTAttachment(screenshot:app.screenshot());arrows.name="Guided solve arrow";arrows.lifetime = .keepAlways;add(arrows)
        if let other=v["legal"]!.split(separator:"|").first(where:{!$0.hasPrefix(v["arrow"]!.prefix(2)) && $0.count==4}) {
            puzzleMove(app,String(other));Thread.sleep(forTimeInterval:0.6);XCTAssertEqual(puzzleValues(app)["moves"],"0","Only the arrowed piece moves")
        }
        let score=v["score"]!
        puzzleMove(app,v["arrow"]!)
        wait("value CONTAINS %@ AND value CONTAINS %@ AND value CONTAINS %@",["moves:2,","guided:1,","ready:1,"])
        v=puzzleValues(app);XCTAssertEqual(v["arrow"]!.count,4,"The next arrow follows the defense")
        puzzleMove(app,v["arrow"]!)
        wait("value CONTAINS %@ AND NOT value CONTAINS %@",["ready:1,","id:\(original["id"]!),"],40)
        let next=puzzleValues(app)
        XCTAssertEqual(next["guided"],"0");XCTAssertEqual(next["arrow"],"");XCTAssertEqual(next["hearts"],"3")
        XCTAssertEqual(next["score"],score,"A guided solve earns nothing");XCTAssertEqual(next["completed"],failed["completed"],"…and records nothing new")
    }
    /// Premium shows when the active plan renews (or ends). StoreKit is replaced by a DEBUG fixture.
    @MainActor func testPremiumShowsRenewalDate() throws {
        continueAfterFailure=false
        for (fixture,expected) in [("yearly-renews","Your yearly plan renews on "),("monthly-ends","Your monthly plan ends on "),("yearly-trial","Your free trial ends on ")] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--reduced-motion","--premium-renewal=\(fixture)"];app.launch();puzzleReady(app)
            app.buttons["Settings"].tap();XCTAssertTrue(app.buttons["Premium"].waitForExistence(timeout:5));app.buttons["Premium"].tap()
            let text=app.staticTexts["subscription-renewal"];XCTAssertTrue(text.waitForExistence(timeout:15))
            XCTAssertTrue(text.label.hasPrefix(expected),text.label)
            XCTAssertTrue(app.descendants(matching:.any)["subscription-active"].exists)
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Premium \(fixture)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    /// The board (and the crowns standing on it) fits between the measured header
    /// and the bottom controls on every shape, for both puzzle titles.
    func testHUDNeverOverlapsBoard() throws {
        continueAfterFailure=false
        for (shape,mate) in [("4x8",2),("4x8",0),("8x8",0),("8x4",2),("6x6",0),("5x7",3),("7x5",0)] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=\(shape)","--puzzle-mate=\(mate)","--reduced-motion","--score=1000000","--cloud-validation"];app.launch();puzzleReady(app)
            let squares=app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","board-plane-")).allElementsBoundByIndex.map(\.frame)
            XCTAssertFalse(squares.isEmpty)
            let boardTop=squares.map(\.minY).min()!,boardBottom=squares.map(\.maxY).max()!
            let pips=app.otherElements["moves-used"].frame
            // The crowns rise above the top row; one square of headroom is a conservative stand-in.
            let squareHeight=squares.map(\.height).max()!
            XCTAssertGreaterThan(boardTop-squareHeight*0.9,pips.maxY+8,"\(shape) mate \(mate): the title cloud clears the crowns")
            let dock=app.buttons["Undo move"].frame
            XCTAssertLessThan(boardBottom,dock.minY-8,"\(shape) mate \(mate): the board clears the dock")
            if mate==0 {XCTAssertLessThan(boardBottom,app.otherElements["material-bar"].frame.minY,"\(shape): the board clears the material bar")}
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="HUD \(shape) mate \(mate)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    /// The skip confirmation also offers the solution (replay or arrows) at the skip's cost.
    func testSkipOffersSolutionChoices() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app)
        let start=puzzleValues(app),value=pow(Double(start["itemRating"]!)!,1.5)
        app.buttons["Skip puzzle"].tap();XCTAssertTrue(app.staticTexts["Skip this puzzle?"].waitForExistence(timeout:5))
        for id in ["confirm-action","skip-solution","skip-guided","cancel-action"] {XCTAssertTrue(app.buttons[id].isHittable,id)}
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Skip with solution choices";shot.lifetime = .keepAlways;add(shot)
        app.buttons["skip-guided"].tap()
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","guided:1,","ready:1,"),evaluatedWith:status);waitForExpectations(timeout:20)
        var v=puzzleValues(app)
        XCTAssertEqual(Double(v["score"]!)!,1_000_000-value*0.5,accuracy:2,"Same cost as a skip");XCTAssertEqual(v["retired"],"1")
        XCTAssertEqual(v["arrow"]!.count,4)
        puzzleMove(app,v["arrow"]!)
        expectation(for:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","moves:2,","ready:1,"),evaluatedWith:status);waitForExpectations(timeout:20)
        v=puzzleValues(app);let score=v["score"]!
        puzzleMove(app,v["arrow"]!)
        expectation(for:NSPredicate(format:"value CONTAINS %@ AND NOT value CONTAINS %@","ready:1,","id:\(start["id"]!),"),evaluatedWith:status);waitForExpectations(timeout:40)
        puzzleReady(app);XCTAssertEqual(puzzleValues(app)["score"],score,"Never charged twice")
        // On the next puzzle, the replay path returns to a "Puzzle skipped" card.
        app.buttons["Skip puzzle"].tap();app.buttons["skip-solution"].tap()
        XCTAssertTrue(app.buttons["close-replay"].waitForExistence(timeout:10));app.buttons["close-replay"].tap()
        XCTAssertTrue(app.staticTexts["Puzzle skipped"].waitForExistence(timeout:5))
        app.buttons["failure-next"].tap();puzzleReady(app);XCTAssertEqual(puzzleValues(app)["retired"],"2")
    }
    func testKingDominoGeneration() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--loading-audit","--board=6x6","--puzzle-mate=1"];app.launch()
        XCTAssertTrue(app.staticTexts["generation-message"].waitForExistence(timeout:15))
        XCTAssertEqual(app.staticTexts["generation-message"].label,"please wait while your puzzle is fully generated by your phone!")
        XCTAssertFalse(app.buttons["square-a1"].exists)
        expectation(for:NSPredicate(format:"value == %@","4 of 10 stages complete"),evaluatedWith:app.otherElements["generation-progress"]);waitForExpectations(timeout:15)
        Thread.sleep(forTimeInterval:1)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Ten king domino loading stages";shot.lifetime = .keepAlways;add(shot)
        puzzleReady(app)
        XCTAssertFalse(app.staticTexts["generation-message"].exists)
        XCTAssertEqual(puzzleValues(app)["generationStep"],"10")
    }
    func testInputAvailableWhileNextBaselineUpdates() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--challenge-fixture=white","--baseline-audit","--reduced-motion"]
        app.launch();puzzleReady(app,timeout:90)
        let next=puzzleValues(app)["next"]!
        puzzleMove(app,next)
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@ AND value CONTAINS %@","ready:1,","moves:2,","evaluating:1,"),evaluatedWith:status)
        waitForExpectations(timeout:20)
        XCTAssertTrue(app.buttons["Hint"].isEnabled)
        let before=puzzleValues(app)
        let legal=before["legal"]!.split(separator:"|").first!
        let from=String(legal.prefix(2));app.buttons["square-"+from].tap()
        XCTAssertEqual(puzzleValues(app)["selected"],from,"Picking a piece must not wait for its baseline")
        XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["error"],"0")
    }
    func testOpeningCurrentTurnPondering() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--challenge-fixture=white","--turn-prefetch-audit","--reduced-motion"]
        app.launch();puzzleReady(app,timeout:90)
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"value CONTAINS %@","preparedMoves:3,"),evaluatedWith:status)
        waitForExpectations(timeout:90)
        let start=Date();puzzleMove(app,"d2d4",drag:true)
        expectation(for:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","ready:1,","moves:2,"),evaluatedWith:status)
        waitForExpectations(timeout:15)
        XCTAssertGreaterThan(Int(puzzleValues(app)["preparedMoveUsed"]!)!,0)
        XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        XCTAssertLessThan(Date().timeIntervalSince(start),15)
        let attachment=XCTAttachment(string:"Warm opening drag through opponent reply: \(Date().timeIntervalSince(start)) seconds, including XCTest gesture overhead")
        attachment.name="Opening turn latency";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testTenMovePreparedBotTurns() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--uitesting","--challenge=tenMoves","--challenge-fixture=middlegame","--turn-prefetch-audit","--reduced-motion","--score=1000000"]
        app.launch();puzzleReady(app,timeout:90)
        let status=app.otherElements["puzzle-status"]
        for turn in 0..<3 {
            let prepared=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in
                let values=self.puzzleValues(app)
                return values["ready"]=="1" && (Int(values["preparedReplies"] ?? "0") ?? 0)>0
            },object:status)
            XCTAssertEqual(XCTWaiter.wait(for:[prepared],timeout:30),.completed,"Preparation: \(status.value ?? "missing")")
            let before=puzzleValues(app),move=before["next"]!
            let start=Date();puzzleMove(app,move,drag:true)
            expectation(for:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","ready:1,","moves:\((turn+1)*2),"),evaluatedWith:status)
            waitForExpectations(timeout:15)
            let after=puzzleValues(app)
            XCTAssertEqual(after["preparedReplyUsed"],String(turn+1))
            XCTAssertEqual(after["score"],"1000000")
            XCTAssertEqual(after["error"],"0")
            XCTAssertFalse(app.otherElements["puzzle-hearts"].exists)
            let receipt=XCTAttachment(string:"Prepared ten-move turn \(turn+1): \(Date().timeIntervalSince(start))s including XCTest gesture overhead; app turn \(after["lastTurnMs"] ?? "?")ms. Frozen opponent: \(after["opponent"] ?? "").")
            receipt.name="Ten-move prepared reply \(turn+1)";receipt.lifetime = .keepAlways;add(receipt)
            puzzleReady(app,timeout:90)
        }
    }
    func testJudgmentCapturePresentationAndTurnColors() throws {
        continueAfterFailure=false
        for (theme,dark,draw) in [(0,"Black",0),(8,"Blue",1),(105,"Green",3),(101,"Purple",0)] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=whosWinning","--judgment-draw=\(draw)","--collection-audit=\(theme)","--score=1000000","--hold-completion","--reduced-motion"]
            app.launch();puzzleReady(app,timeout:90)
            XCTAssertEqual(app.buttons["judgment-white"].label,"White")
            XCTAssertEqual(app.buttons["judgment-black"].label,dark)
            let turn=app.staticTexts["judgment-turn"]
            XCTAssertEqual(turn.label,(puzzleValues(app)["side"]=="white" ? "White":dark)+" to move")
            XCTAssertTrue(app.frame.contains(turn.frame))
            for (owner,label,opponent) in [("white","White",dark.lowercased()),("black",dark,"white")] {
                let card=app.otherElements["captured-by-"+owner]
                XCTAssertEqual(card.label,label+" captured")
                XCTAssertTrue(app.frame.contains(card.frame))
                let value=card.value as? String ?? ""
                XCTAssertTrue(value.contains("No pieces") || value.contains(opponent),"Trophies must show the opponent's color: \(value)")
                XCTAssertTrue(value.contains("points"))
            }
            let image=XCTAttachment(screenshot:app.screenshot());image.name="Judgment captures and turn — \(theme)";image.lifetime = .keepAlways;add(image)
            app.terminate()
        }
    }
    func testJudgmentChoicesColorsCapturesAndScore() throws {
        continueAfterFailure=false
        for (draw,answer) in [(0,"black"),(1,"even"),(3,"white")] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=whosWinning","--judgment-draw=\(draw)","--collection-audit=101","--score=1000000","--hold-completion","--reduced-motion"]
            app.launch();puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["judgmentAnswer"],answer)
            XCTAssertTrue(app.otherElements["captured-by-white"].exists)
            XCTAssertTrue(app.otherElements["captured-by-black"].exists)
            XCTAssertFalse(app.buttons["Hint"].exists)
            XCTAssertNotEqual(app.buttons["judgment-white"].label,app.buttons["judgment-black"].label)
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Judgment board — \(answer)";shot.lifetime = .keepAlways;add(shot)
            let wrong=answer=="white" ? "black":"white"
            app.buttons["judgment-"+wrong].tap();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["hearts"],"2")
            XCTAssertEqual(puzzleValues(app)["mistakeFeedback"],"1")
            XCTAssertLessThan(Int(puzzleValues(app)["score"]!)!,1000000)
            app.buttons["judgment-"+answer].tap()
            expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:15)
            XCTAssertEqual(puzzleValues(app)["scoreDirection"],"1")
            app.terminate()
        }
    }
    func testJudgmentThreeAttemptsReplaceWithoutWipingScore() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=whosWinning","--judgment-draw=0","--score=1000000","--reduced-motion"]
        app.launch();puzzleReady(app)
        let before=puzzleValues(app),base=Double(before["reward"]!)!
        for _ in 0..<3 {app.buttons["judgment-white"].tap();puzzleReady(app)}
        XCTAssertNotEqual(puzzleValues(app)["id"],before["id"])
        XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,max(0,1000000-base*2.5),accuracy:3)
        XCTAssertEqual(puzzleValues(app)["completed"],"1","Failure records one attempt without a reward")
    }
    func testBlunderPunishTimedInjectionAndThreeMoveHold() throws {
        continueAfterFailure=false
        for seed in [12,13] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=blunderPunish","--blunder-seed=\(seed)","--score=200000","--hold-completion","--reduced-motion"]
            app.launch();puzzleReady(app,timeout:180)
            XCTAssertFalse(app.otherElements["puzzle-hearts"].exists)
            var injected=false
            for _ in 0..<6 {
                if puzzleValues(app)["completed"]=="1" {break}
                let next=puzzleValues(app)["next"]!
                XCTAssertEqual(next.count,4)
                puzzleMove(app,next,drag:true)
                let status=app.otherElements["puzzle-status"]
                expectation(for:NSPredicate(format:"(value CONTAINS %@ AND value CONTAINS %@) OR value CONTAINS %@","ready:1,","evaluating:0,","completed:1,"),evaluatedWith:status);waitForExpectations(timeout:180)
                if let ply=Int(puzzleValues(app)["blunderPly"]!),ply>0 {
                    injected=true;XCTAssertTrue(ply==4 || ply==6)
                }
                XCTAssertEqual(puzzleValues(app)["error"],"0")
            }
            XCTAssertTrue(injected)
            XCTAssertEqual(puzzleValues(app)["completed"],"1")
            XCTAssertEqual(puzzleValues(app)["blunderProgress"],"3")
            XCTAssertGreaterThan(Int(puzzleValues(app)["score"]!)!,200000)
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Blunder punished for three moves — \(seed)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    func testOpeningDrillAcceptsAlternatives() throws {
        continueAfterFailure=false
        for side in ["white","black"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--challenge-fixture=\(side)","--hold-completion","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app,timeout:180)
            XCTAssertEqual(puzzleValues(app)["kind"],"opening")
            let alternative=side=="white" ? "d2d4":"c7c5"
            puzzleMove(app,alternative);puzzleReady(app,timeout:180)
            XCTAssertEqual(puzzleValues(app)["moves"],"2");XCTAssertEqual(puzzleValues(app)["mistakes"],"0")
            XCTAssertEqual(puzzleValues(app)["hearts"],"3")
            puzzleMove(app,puzzleValues(app)["next"]!);puzzleReady(app,timeout:180)
            puzzleMove(app,puzzleValues(app)["next"]!)
            expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:180)
            XCTAssertEqual(puzzleValues(app)["completed"],"1")
            XCTAssertGreaterThan(Double(puzzleValues(app)["score"]!)!,1_000_000)
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Offline opening drill - \(side)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    func testOpenPlayHasNoHeartsOrMovePenalty() throws {
        continueAfterFailure=false
        for mode in ["finish","tenMoves"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=\(mode)","--challenge-fixture=white","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app,timeout:90)
            XCTAssertFalse(app.otherElements["puzzle-hearts"].exists)
            let before=puzzleValues(app),value=pow(Double(before["itemRating"]!)!,1.5)*(mode=="finish" ? 3:2.5)
            puzzleMove(app,"g6g4");puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["score"],"1000000","No centipawn loss charge in open play")
            XCTAssertEqual(puzzleValues(app)["scoreEvents"],"0")
            app.buttons["Undo move"].tap();puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["score"],"1000000")
            XCTAssertEqual(puzzleValues(app)["scoreEvents"],"0","Undo only reduces the future reward")
            XCTAssertEqual(Double(puzzleValues(app)["reward"]!)!,value*0.8,accuracy:2)
            puzzleMove(app,"g6g8")
            expectation(for:NSPredicate(format:"value CONTAINS %@","phase:failed,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:90)
            XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,max(0,1_000_000-value*2),accuracy:2)
            XCTAssertEqual(puzzleValues(app)["best"],"1000000")
            XCTAssertEqual(puzzleValues(app)["scoreDirection"],"-1")
            XCTAssertEqual(puzzleValues(app)["scoreEvents"],"1")
            XCTAssertEqual(puzzleValues(app)["mistakeFeedback"],"2","The free open-play mistake and the final loss each give board feedback")
            XCTAssertEqual(puzzleValues(app)["evaluating"],"0")
            app.terminate()
        }
    }
    func testOpeningBlundersUseThreeAttempts() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--challenge-fixture=blunder","--reduced-motion","--score=1000000"];app.launch();puzzleReady(app,timeout:120)
        let initial=puzzleValues(app),value=pow(Double(initial["itemRating"]!)!,1.5)
        for attempt in 1...3 {
            puzzleMove(app,"g2g4");puzzleReady(app,timeout:180)
            if attempt<3 {
                XCTAssertEqual(puzzleValues(app)["mistakeFeedback"],String(attempt))
                XCTAssertEqual(puzzleValues(app)["scoreEvents"],String(attempt))
                XCTAssertEqual(puzzleValues(app)["outcomeHaptics"],String(attempt))
                XCTAssertEqual(puzzleValues(app)["moves"],"0","Rejected opening remains at decision point")
                XCTAssertEqual(puzzleValues(app)["hearts"],String(3-attempt))
                XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,1_000_000-Double(attempt)*value*0.25,accuracy:2)
            }
        }
        XCTAssertNotEqual(puzzleValues(app)["id"],initial["id"])
        XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,max(0,1_000_000-value*2.5),accuracy:2)
    }
    func testGeneratedOpenModesAdaptToSkill() throws {
        continueAfterFailure=false
        for mode in ["finish","tenMoves"] {
            var opponents:[Int]=[],ratings:[Int]=[]
            for score in [0,2_000_000] {
                let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=\(mode)","--learner=1100","--score=\(score)","--reduced-motion"];app.launch();puzzleReady(app,timeout:240)
                let p=puzzleValues(app)
                XCTAssertEqual(p["kind"],mode);XCTAssertEqual(p["difficulty"],mode=="tenMoves" ? "mode-bots-v3-six-v1":"mode-bots-v3");XCTAssertEqual(p["generationStep"],"10")
                XCTAssertFalse(app.otherElements["puzzle-hearts"].exists)
                opponents.append(Int(p["opponent"]!)!);ratings.append(Int(p["itemRating"]!)!)
                XCTAssertGreaterThanOrEqual(ratings.last!,400);XCTAssertLessThanOrEqual(ratings.last!,3000)
                puzzleMove(app,p["next"]!);puzzleReady(app,timeout:120)
                XCTAssertEqual(puzzleValues(app)["moves"],"2");XCTAssertEqual(puzzleValues(app)["error"],"0")
                let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Generated \(mode), score \(score), item \(ratings.last!), opponent \(opponents.last!)";shot.lifetime = .keepAlways;add(shot)
                app.terminate()
            }
            XCTAssertGreaterThan(opponents[1]-opponents[0],300)
            XCTAssertGreaterThan(ratings[1],ratings[0],"Higher current score must produce harder measured challenges at fixed skill")
        }
    }
    func testGeneratedOpeningBook() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--reduced-motion"];app.launch();puzzleReady(app,timeout:180)
        XCTAssertTrue((puzzleValues(app)["id"] ?? "").hasPrefix("opening-O"))
        XCTAssertEqual(puzzleValues(app)["difficulty"],"mode-bots-v3")
        XCTAssertEqual(puzzleValues(app)["generationStep"],"10")
        XCTAssertLessThanOrEqual(abs(Int(puzzleValues(app)["cp"]!)!),120)
        XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Book-generated opening position";shot.lifetime = .keepAlways;add(shot)
    }
    func testScoreNeverNegative() throws {
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--reduced-motion"];app.launch();puzzleReady(app)
        Thread.sleep(forTimeInterval:3);XCTAssertEqual(puzzleValues(app)["score"],"0")
        app.buttons["Skip puzzle"].tap();app.buttons["confirm-action"].tap();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["score"],"0")
    }
    func testZeroScoreHasNoHiddenDebt() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--hold-completion","--reduced-motion"];app.launch();puzzleReady(app)
        let initial=puzzleValues(app),winning=Set(initial["winning"]!.split(separator:"|"))
        let bad=initial["legal"]!.split(separator:"|").first{!winning.contains($0) && $0.count==4}!
        puzzleMove(app,String(bad));puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["score"],"0")
        XCTAssertEqual(puzzleValues(app)["hearts"],"2")
        XCTAssertEqual(puzzleValues(app)["mistakeFeedback"],"1")
        XCTAssertEqual(puzzleValues(app)["scoreEvents"],"0","No fictitious score decrease at zero")
        XCTAssertEqual(puzzleValues(app)["outcomeHaptics"],"1","A zero-point mistake still has warning haptics")
        puzzleMove(app,puzzleValues(app)["next"]!)
        expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:40)
        let value=pow(Double(initial["itemRating"]!)!,1.5)
        XCTAssertEqual(Double(puzzleValues(app)["score"]!)!,value,accuracy:2,"A mistake at zero cannot reduce the next earned reward")
        XCTAssertEqual(puzzleValues(app)["hearts"],"2")
    }
    func testFinishAndPersonalModesBothColors() throws {
        continueAfterFailure=false
        for mode in ["finish","personal"] {for side in ["white","black"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=\(mode)","--challenge-fixture=\(side)","--hold-completion","--reduced-motion"];app.launch();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["side"],side)
            XCTAssertTrue(app.staticTexts[mode=="finish" ? "Finish the job":"From one of your games"].exists)
            puzzleMove(app,puzzleValues(app)["next"]!,drag:true)
            expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:40)
            XCTAssertEqual(puzzleValues(app)["mistakes"],"0");XCTAssertEqual(puzzleValues(app)["error"],"0")
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="\(mode)-\(side)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }}
    }
    func testRewardDoorsReducedMotionAndNoText() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--reward-doors","--reduced-motion"];app.launch()
        if !app.buttons["reward-door-8"].waitForExistence(timeout:10) {print(app.debugDescription)}
        XCTAssertTrue(app.buttons["reward-door-8"].exists)
        for i in 0..<9 {XCTAssertTrue(app.buttons["reward-door-\(i)"].isHittable)}
        XCTAssertEqual(app.descendants(matching:.any)["reward-doors-presentation"].staticTexts.count,0,"The reward screen has no visible prose")
        app.buttons["reward-door-8"].tap();app.buttons["reward-door-2"].tap()
        XCTAssertTrue(app.buttons["claim-reward"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["claim-reward"].isHittable)
        for i in 0..<9 {
            let door=app.buttons["reward-door-\(i)"]
            XCTAssertTrue(app.frame.insetBy(dx:8,dy:8).contains(door.frame),"Every revealed door remains inside the screen")
        }
        XCTAssertEqual(puzzleValues(app)["rewardOwned"],"2")
        XCTAssertEqual(app.descendants(matching:.any)["reward-doors-presentation"].staticTexts.count,0)
        let reveal=XCTAttachment(screenshot:app.screenshot());reveal.name="Compact text-free reward board";reveal.lifetime = .keepAlways;add(reveal)
    }
    func testBackgroundPreparationKeepsInputResponsive() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--puzzle-mate=1","--reduced-motion","--prefetch-audit","--hold-completion"]
        app.launch();puzzleReady(app)
        let status=app.otherElements["puzzle-status"]
        expectation(for:NSPredicate(format:"NOT (value CONTAINS %@)","preparedReady:0,"),evaluatedWith:status)
        waitForExpectations(timeout:180)
        let move=puzzleValues(app)["next"]!
        XCTAssertEqual(move.count,4)
        puzzleMove(app,move,drag:true)
        expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:status)
        waitForExpectations(timeout:40)
        XCTAssertEqual(puzzleValues(app)["error"],"0")
    }
    func testAtelierInteractionAcrossShapes() throws {
        continueAfterFailure=false
        for (theme,shape,side) in [(1,"4x6","white"),(104,"6x4","black"),(122,"8x8","black")] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=\(shape)","--puzzle-mate=2","--solver=\(side)","--collection-audit=\(theme)","--hold-completion","--reduced-motion"]
            app.launch();puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["pieceTheme"],String(theme))
            puzzleMove(app,puzzleValues(app)["next"]!,drag:true);puzzleReady(app,timeout:90)
            XCTAssertEqual(puzzleValues(app)["mistakes"],"0")
            puzzleMove(app,puzzleValues(app)["next"]!)
            expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"])
            waitForExpectations(timeout:90)
            XCTAssertEqual(puzzleValues(app)["completed"],"1")
            app.terminate()
        }
    }
    func testLoadingAndAnalysisMainThreadCadence() throws {
        continueAfterFailure=false
        // The focused release converts every non-tactical fixture to tactics, so
        // the audit now drags a certified mate-in-two move with speculation on.
        let app=XCUIApplication()
        app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--smoothness-audit","--prefetch-audit"]
        app.launch();puzzleReady(app,timeout:90)
        puzzleMove(app,puzzleValues(app)["next"]!,drag:true);puzzleReady(app,timeout:90)
        XCTAssertEqual(puzzleValues(app)["moves"],"2")
        XCTAssertEqual(puzzleValues(app)["hearts"],"3")
        XCTAssertEqual(puzzleValues(app)["boardMatches"],"1")
        Thread.sleep(forTimeInterval:16) // Includes cold generation, drop, save and the real full-budget proof.
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Responsive tactical turn";shot.lifetime = .keepAlways;add(shot)
    }
    func testTacticalTurnLatencyEvidence() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2","--prefetch-audit","--smoothness-audit"]
        app.launch();puzzleReady(app,timeout:90)
        let status=app.otherElements["puzzle-status"]
        let start=Date();puzzleMove(app,puzzleValues(app)["next"]!,drag:true)
        expectation(for:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","ready:1,","moves:2,"),evaluatedWith:status)
        waitForExpectations(timeout:30)
        let values=puzzleValues(app)
        XCTAssertEqual(values["hearts"],"3");XCTAssertEqual(values["boardMatches"],"1")
        XCTAssertGreaterThan(Int(values["lastTurnMs"]!)!,0)
        print("TURN_LATENCY lastTurnMs=\(values["lastTurnMs"]!) wallMs=\(Int(Date().timeIntervalSince(start)*1000)) id=\(values["id"]!)")
        let attachment=XCTAttachment(string:"Tactical drag through defence reply: lastTurnMs=\(values["lastTurnMs"]!) (drop to input unlock, in-app), wall \(Date().timeIntervalSince(start)) s including XCTest gesture overhead")
        attachment.name="Tactical turn latency";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testJourneyWithCompositions() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--uitesting","--board=8x8","--puzzle-mate=0","--compose","--prefetch-audit"]
        app.launch();puzzleReady(app,timeout:120)
        let status=app.otherElements["puzzle-status"]
        for round in 0..<5 {
            let before=puzzleValues(app)["id"]!
            var plies=0
            while puzzleValues(app)["id"]==before && plies<10 {
                plies+=1
                let next=puzzleValues(app)["next"]!;XCTAssertGreaterThanOrEqual(next.count,4,"Certified line available")
                puzzleMove(app,next)
                let settled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@ AND value CONTAINS %@","ready:1,","evaluating:0,"),object:status)
                XCTAssertEqual(XCTWaiter.wait(for:[settled],timeout:120),.completed,"Puzzle readiness: \(status.value ?? "missing")")
                dismissInstructions(app)
            }
            let v=puzzleValues(app)
            XCTAssertNotEqual(v["id"],before,"Round \(round) reached the next puzzle")
            XCTAssertEqual(v["error"],"0");XCTAssertEqual(v["boardMatches"],"1")
            print("JOURNEY_COMPOSE round=\(round) lastJourneyMs=\(v["lastJourneyMs"]!) journeyFallbacks=\(v["journeyFallbacks"]!) preparedUsed=\(v["preparedUsed"]!) id=\(v["id"]!)")
        }
    }
    func testAtelierFullBoardCadence() throws {
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=8x8","--piece-gallery","--collection-audit=122","--atelier-frame-audit","--render-audit"]
        app.launch();puzzleReady(app,timeout:90)
        Thread.sleep(forTimeInterval:12) // Sample a whole-board rendering window, including animated clouds.
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Legendary full-board rendering audit";image.lifetime = .keepAlways;add(image)
        XCTAssertEqual(puzzleValues(app)["pieceTheme"],"122")
    }
    func testWorldsArtAudit() throws {
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--challenge-fixture=white","--art-audit","--premium-art-audit","--reduced-motion"]
        app.launch();puzzleReady(app,timeout:240)
    }
    func testPremiumScenePhotos() throws {
        continueAfterFailure=false
        for theme in [1,2,3,4,5,6,7,8,9,10,101,102,103,104,105,121,122] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=opening","--challenge-fixture=white","--collection-audit=\(theme)","--reduced-motion"];app.launch();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["pieceTheme"],String(theme));XCTAssertEqual(puzzleValues(app)["boardTheme"],String(theme))
            XCTAssertTrue(app.buttons["square-e1"].label.contains("king"))
            Thread.sleep(forTimeInterval:1) // Let the SceneKit entrance complete before photographing it.
            let image=XCTAttachment(screenshot:app.screenshot());image.name="Premium full board \(theme)";image.lifetime = .keepAlways;add(image)
            app.terminate()
        }
    }
    func testPremiumCollectionAndColorNames() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--challenge-fixture=black","--collection-audit=101","--reduced-motion"];app.launch();puzzleReady(app)
        XCTAssertEqual(app.staticTexts["evaluation-verdict"].label,"Purple is winning")
        openCollection(app)
        let gallery=app.descendants(matching:.any)["collection-gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout:5))
        app.buttons["Rare"].tap()
        XCTAssertTrue(app.buttons["collection-board-101"].waitForExistence(timeout:5))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Rare collection popup";shot.lifetime = .keepAlways;add(shot)
        app.buttons["collection-board-101"].tap();XCTAssertTrue(app.buttons["accept-skin"].waitForExistence(timeout:5));app.buttons["accept-skin"].tap()
        app.buttons["Settings"].tap();XCTAssertFalse(app.buttons["Debug menu"].exists)
        app.buttons["Close settings"].tap()
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"101")

    }
    func testHorizontalEvaluationBar() throws {
        continueAfterFailure=false
        for side in ["white","black","even"] {
            let app=XCUIApplication()
            app.launchArguments=["--uitesting","--challenge=tenMoves","--hold-completion","--reduced-motion"]
            if side != "even" {app.launchArguments.append("--challenge-fixture=\(side)")}
            app.launch();puzzleReady(app,timeout:180)
            let label=app.staticTexts["evaluation-verdict"],bar=app.otherElements["evaluation-bar"]
            XCTAssertTrue(label.waitForExistence(timeout:5))
            XCTAssertEqual(label.label,side=="even" ? "The position is even":(side=="white" ? "White is winning":"Black is winning"))
            XCTAssertGreaterThan(bar.frame.width,bar.frame.height*2,"A horizontal evaluation bar")
            XCTAssertGreaterThan(bar.frame.minY,app.frame.height*0.70,"Evaluation belongs below the board")
            XCTAssertLessThan(bar.frame.maxY,app.buttons["Undo move"].frame.minY,"Evaluation must not overlap bottom controls")
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Bottom horizontal evaluation bar - \(side)";shot.lifetime = .keepAlways;add(shot)
            app.buttons["Challenge information"].tap()
            XCTAssertTrue(app.descendants(matching:.any)["instruction-panel"].waitForExistence(timeout:5))
            XCTAssertFalse(label.exists,"The instructions popup conceals the evaluation")
            dismissInstructions(app);puzzleReady(app)
            XCTAssertEqual(label.label,side=="even" ? "The position is even":(side=="white" ? "White is winning":"Black is winning"))
            app.terminate()
        }
    }
    func testUndoInSixMoveChallenge() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--reduced-motion"];app.launch();puzzleReady(app,timeout:180)
        let original=puzzleValues(app)
        puzzleMove(app,original["next"]!);puzzleReady(app,timeout:60)
        XCTAssertEqual(puzzleValues(app)["moves"],"2")
        app.buttons["Undo move"].tap();puzzleReady(app,timeout:60)
        let undone=puzzleValues(app)
        XCTAssertEqual(undone["moves"],"0");XCTAssertEqual(undone["undos"],"1")
        XCTAssertEqual(undone["id"],original["id"]);XCTAssertEqual(undone["legal"],original["legal"])
        XCTAssertEqual(Double(undone["reward"]!)!,Double(original["reward"]!)!*0.8,accuracy:2)
        XCTAssertTrue(app.staticTexts["0 / 6"].exists);XCTAssertEqual(undone["error"],"0")
    }
    func testColdSixMoveReadiness() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--reduced-motion"]
        let start=Date();app.launch();puzzleReady(app,timeout:8)
        let seconds=Date().timeIntervalSince(start)
        print("COLD_SIX_MOVE_READY_SECONDS=\(seconds)")
        XCTAssertEqual(puzzleValues(app)["searchExecuted"],"0","Cold start must reuse bundled full-strength certification, with disk caching disabled")
        XCTAssertTrue(app.staticTexts["0 / 6"].exists)
        XCTAssertTrue(app.otherElements["evaluation-bar"].exists)
        XCTAssertEqual(puzzleValues(app)["error"],"0")
        XCTAssertLessThan(seconds,10,"Includes app launch, board assets, instructions acknowledgement and initial evaluation")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Six move cold start";shot.lifetime = .keepAlways;add(shot)
    }
    func testGeneratedSixMoveChallenge() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--challenge=tenMoves","--hold-completion","--reduced-motion"];app.launch();puzzleReady(app,timeout:180)
        XCTAssertLessThanOrEqual(abs(Int(puzzleValues(app)["cp"]!)!),10)
        XCTAssertTrue(app.otherElements["evaluation-bar"].exists)
        let start=puzzleValues(app)["id"]!,initialCP=Int(puzzleValues(app)["cp"]!)!
        for turn in 0..<6 {
            // The board intentionally unlocks before the next baseline arrives.
            // This test chooses the engine's best move, so await that evidence.
            puzzleReady(app,timeout:120)
            let values=puzzleValues(app);XCTAssertEqual(values["id"],start)
            XCTAssertEqual(values["moves"],String(turn*2))
            puzzleMove(app,values["next"]!)
            expectation(for:NSPredicate(format:"value CONTAINS %@ OR value CONTAINS %@","ready:1,","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"])
            waitForExpectations(timeout:120)
            if puzzleValues(app)["completed"]=="1" {break}
        }
        expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:120)
        let plies=Int(puzzleValues(app)["moves"]!)!
        XCTAssertLessThanOrEqual(plies,12)
        if plies<12 {XCTAssertGreaterThanOrEqual(Int(puzzleValues(app)["cp"]!)!,99000,"An early completion must be a terminal win")}
        XCTAssertEqual(puzzleValues(app)["error"],"0")
        XCTAssertGreaterThan(Int(puzzleValues(app)["cp"]!)!,initialCP)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Six moves judged";shot.lifetime = .keepAlways;add(shot)
    }
    func testLegalTileBehindEnemyCrown() throws {
        continueAfterFailure=false
        for side in ["white","black"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--occluded-target","--solver=\(side)","--reduced-motion"];app.launch();puzzleReady(app)
            let before=puzzleValues(app)
            XCTAssertEqual(before["next"],side=="white" ? "a6d6":"a1d1")
            puzzleMove(app,before["next"]!);puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["completed"],"1","An enemy king silhouette must not swallow the mating destination")
            app.terminate()
        }
    }
    func testAdaptiveMeasuredDifficultyProgression() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--compose","--board=6x6","--reduced-motion"];app.launch();puzzleReady(app)
        var ratings:[Int]=[]
        for completed in 0..<8 {
            let initial=puzzleValues(app);ratings.append(Int(initial["itemRating"]!)!)
            XCTAssertEqual(initial["difficulty"],"challenge-v2")
            var moves=0
            while puzzleValues(app)["completed"]==String(completed) && moves<6 {
                let before=puzzleValues(app)
                puzzleMove(app,before["next"]!);puzzleReady(app);moves+=1
                let after=puzzleValues(app)
                XCTAssertTrue(after["id"] != before["id"] || after["next"] != before["next"],"Expected move did not advance: before=\(before), after=\(after)")
            }
            XCTAssertEqual(puzzleValues(app)["completed"],String(completed+1))
            XCTAssertNotEqual(puzzleValues(app)["id"],initial["id"])
            XCTAssertEqual(puzzleValues(app)["mistakes"],"0")
        }
        print("Measured difficulty trajectory: \(ratings)")
        let first=ratings.prefix(3).reduce(0,+)/3,last=ratings.suffix(3).reduce(0,+)/3
        XCTAssertGreaterThan(last,first+200,"Actual generated challenges must rise with fast accurate play: \(ratings)")
        XCTAssertFalse(app.staticTexts["White to solve"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Adaptive measured challenge";shot.lifetime = .keepAlways;add(shot)
    }
    func testSolverOrientationAndInput() throws {
        continueAfterFailure=false
        for shape in [(8,8),(4,6),(7,5)] {for side in ["black","white"] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=\(shape.0)x\(shape.1)","--puzzle-mate=2","--solver=\(side)","--reduced-motion"];app.launch();puzzleReady(app)
            func assertOrientation() {
                XCTAssertEqual(puzzleValues(app)["side"],side)
                let a=app.buttons["square-a1"].frame,b=app.buttons["square-\(UnicodeScalar(96+shape.0)!)\(shape.1)"].frame
                if side=="black" {XCTAssertGreaterThan(a.midX,b.midX);XCTAssertLessThan(a.midY,b.midY)}
                else {XCTAssertLessThan(a.midX,b.midX);XCTAssertGreaterThan(a.midY,b.midY)}
            }
            assertOrientation()
            puzzleMove(app,puzzleValues(app)["next"]!,drag:true);puzzleReady(app);assertOrientation()
            let id=puzzleValues(app)["id"]
            app.terminate();app.launchArguments=["--uitesting","--preserve-coach","--reduced-motion"];app.launch();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["id"],id);assertOrientation()
            puzzleMove(app,puzzleValues(app)["next"]!);puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["completed"],"1");XCTAssertFalse(app.staticTexts["White to solve"].exists)
            app.terminate()
        }}
    }
    func testPieceReadabilityGallery() throws {
        continueAfterFailure=false
        for (theme,shape) in [(0,"8x8"),(1,"4x6"),(103,"6x4"),(122,"8x8")] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=\(shape)","--collection-audit=\(theme)","--piece-gallery","--solver=white","--reduced-motion"];app.launch();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["boardTheme"],String(theme));XCTAssertEqual(puzzleValues(app)["pieceTheme"],String(theme))
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Themed piece readability \(theme) on \(shape)";shot.lifetime = .keepAlways;add(shot)
            app.terminate()
        }
    }
    func testContinuousPuzzlesAcrossEveryShape() throws {
        continueAfterFailure=false
        for c in 4...8 {for r in 4...8 {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=\(c)x\(r)","--puzzle-mate=1","--reduced-motion"];app.launch();puzzleReady(app)
            let before=puzzleValues(app);let move=before["next"]!
            XCTAssertEqual(app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","square-")).count,c*r)
            puzzleMove(app,move,drag:c != r)
            expectation(for:NSPredicate(format:"value CONTAINS %@","completed:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:30)
            puzzleReady(app)
            let after=puzzleValues(app)
            XCTAssertNotEqual(after["id"],before["id"]);XCTAssertGreaterThan(Int(after["rating"]!)!,Int(before["rating"]!)!)
            XCTAssertEqual(after["confetti"],"0");XCTAssertEqual(after["bursts"],"1")
            XCTAssertFalse(app.staticTexts["White to solve"].exists)
            if c==4 && r==6 || c==8 && r==8 {let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Continuous puzzle \(c)x\(r)";shot.lifetime = .keepAlways;add(shot)}
            app.terminate()
        }}
    }
    func testPuzzleMistakesHintsResumeAndCelebration() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=2"];app.launch();puzzleReady(app)
        let initial=puzzleValues(app)
        puzzleMove(app,initial["next"]!);puzzleReady(app)
        let current=puzzleValues(app)
        let winning=Set(current["winning"]!.split(separator:"|").map(String.init))
        let wrong=current["legal"]!.split(separator:"|").map(String.init).first{!winning.contains($0)}!
        puzzleMove(app,wrong)
        expectation(for:NSPredicate(format:"value CONTAINS %@","mistakes:1,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:15);puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["id"],initial["id"])
        app.buttons["Hint"].tap();app.buttons["confirm-action"].tap();puzzleReady(app);XCTAssertEqual(puzzleValues(app)["hints"],"1")
        app.terminate();app.launchArguments=["--uitesting","--preserve-coach","--board=6x6","--puzzle-mate=2"];app.launch();puzzleReady(app)
        let resumed=puzzleValues(app)
        XCTAssertEqual(resumed["id"],initial["id"],"Returning resumes the admitted puzzle")
        XCTAssertEqual(resumed["moves"],"2");XCTAssertEqual(resumed["mistakes"],"1");XCTAssertEqual(resumed["hints"],"1")
        XCTAssertEqual(resumed["completed"],"0","Returning is not a solve")
        let freshRating=Int(resumed["rating"]!)!
        puzzleMove(app,resumed["next"]!)
        expectation(for:NSPredicate(format:"value CONTAINS %@","confetti:96,"),evaluatedWith:app.otherElements["puzzle-status"]);waitForExpectations(timeout:12)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Confetti above the clouds";shot.lifetime = .keepAlways;add(shot)
        puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["completed"],"1")
        XCTAssertLessThanOrEqual(Int(puzzleValues(app)["rating"]!)!,freshRating,"A solve after a lost heart and a hint is not clean mastery")
        app.terminate();app.launchArguments=["--uitesting","--preserve-coach"];app.launch();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["completed"],"1","Celebration never double-counts a solve")
        XCTAssertFalse(app.staticTexts["White to solve"].exists)
    }
    func testLongMatesMaterialAndBoardPreferences() throws {
        continueAfterFailure=false
        for mate in [0,3,4,5] {
            let app=XCUIApplication();app.launchArguments=["--uitesting","--board=5x5","--puzzle-mate=\(mate)","--reduced-motion"];app.launch();puzzleReady(app)
            var played=0
            while puzzleValues(app)["completed"]=="0",played<6 {
                let move=puzzleValues(app)["next"]!;XCTAssertFalse(move.isEmpty);puzzleMove(app,move);puzzleReady(app);played+=1
            }
            XCTAssertEqual(puzzleValues(app)["completed"],"1")
            let before=puzzleValues(app)
            openCollection(app);app.buttons["Close collection"].tap();puzzleReady(app)
            XCTAssertEqual(puzzleValues(app)["rating"],before["rating"],"Viewing the collection is not a chess failure")
            XCTAssertEqual(puzzleValues(app)["completed"],"1")
            XCTAssertFalse(app.staticTexts["White to solve"].exists);app.terminate()
        }
    }

    func testOnDeviceProfileAndOfflineStandardPlay() throws {
        throw XCTSkip("Profile analysis is switched off in 2.1 (ProfileAnalysisFeature.enabled)")
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=8x8","--puzzle-mate=1","--profile-autostart=https://lichess.org/@/thibault","--profile-limit=1"];app.launch();puzzleReady(app)
        app.buttons["Settings"].tap();app.buttons["Profile analysis"].tap()
        let status=app.otherElements["profile-analysis-status"]
        XCTAssertTrue(status.waitForExistence(timeout:5))
        // Interim reports appear while analysing; a full 2M/4M game exceeds a UI-test budget.
        XCTAssertTrue(app.otherElements["profile-analysis-report"].waitForExistence(timeout:240));XCTAssertFalse(app.staticTexts["White to solve"].exists)
        app.buttons["Close profile analysis"].tap()
        puzzleMove(app,puzzleValues(app)["next"]!);puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["completed"],"1")
        app.terminate();app.launchArguments=["--uitesting","--preserve-profile","--preserve-coach"];app.launch();puzzleReady(app)
        app.buttons["Settings"].tap();app.buttons["Profile analysis"].tap()
        XCTAssertTrue(app.otherElements["profile-analysis-report"].waitForExistence(timeout:15));XCTAssertFalse(app.staticTexts["White to solve"].exists)
    }
    func testFreshCompositionsAndBackgroundResume() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--compose","--reduced-motion"];app.launch();puzzleReady(app)
        let id=puzzleValues(app)["id"]!
        XCUIDevice.shared.press(.home);app.activate();puzzleReady(app)
        XCTAssertNotEqual(puzzleValues(app)["id"],id)
        var moves=0
        while Int(puzzleValues(app)["completed"] ?? "0")!<3,moves<18 {
            puzzleMove(app,puzzleValues(app)["next"]!,drag:true);puzzleReady(app);moves+=1
        }
        XCTAssertEqual(puzzleValues(app)["completed"],"3");XCTAssertFalse(app.staticTexts["White to solve"].exists)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Adaptive fresh composition";shot.lifetime = .keepAlways;add(shot)
    }


    func testFocusedPuzzlesHideCollectionAndRewards() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--reward-doors","--challenge=opening","--automatic-mix","--reduced-motion"]
        app.launch();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["kind"],"tactics")
        XCTAssertEqual(puzzleValues(app)["rewardBoard"],"0")
        app.buttons["Settings"].tap()
        for label in ["Dream collection","Collection","Board size","Board style","Challenges","Debug menu"] {XCTAssertFalse(app.buttons[label].exists)}
        app.buttons["Close settings"].tap()
        let initial=puzzleValues(app)["instructionType"]!
        app.buttons["Skip puzzle"].tap()
        app.buttons["confirm-action"].tap()
        puzzleReady(app)
        XCTAssertNotEqual(puzzleValues(app)["instructionType"],initial)
        XCTAssertEqual(puzzleValues(app)["kind"],"tactics")
    }
    private func meanLuminance(_ app:XCUIApplication,crop rect:CGRect?)->Double {
        let image=app.screenshot().image.cgImage!
        let region=rect.map {r->CGRect in let f=CGFloat(image.width)/app.frame.width;return CGRect(x:r.minX*f,y:r.minY*f,width:r.width*f,height:r.height*f)}
            ?? CGRect(x:0,y:Double(image.height)*0.73,width:Double(image.width)*0.95,height:Double(image.height)*0.08)
        let crop=image.cropping(to:region)!
        let context=CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
        let bytes=context.data!.assumingMemoryBound(to:UInt8.self);var total=0.0
        for i in stride(from:0,to:crop.width*crop.height*4,by:4) {total+=0.2126*Double(bytes[i])+0.7152*Double(bytes[i+1])+0.0722*Double(bytes[i+2])}
        return total/Double(crop.width*crop.height)
    }
    private func expectSidePulse(_ app:XCUIApplication,_ count:String,_ message:String="") {
        let shown=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulse:\(count),"),object:app.otherElements["puzzle-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[shown],timeout:5),.completed,"\(message) sidePulse expected \(count): \(puzzleValues(app)["sidePulse"] ?? "missing")")
    }
    func testNightModeToggleDarkensSkyKeepsBoardAndPersists() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=8x8","--puzzle-mate=2","--cloud-validation","--reduced-motion"];app.launch();puzzleReady(app)
        let toggle=app.buttons["night-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout:10));XCTAssertTrue(toggle.isHittable)
        XCTAssertGreaterThanOrEqual(toggle.frame.width,44);XCTAssertGreaterThanOrEqual(toggle.frame.height,44)
        XCTAssertGreaterThan(toggle.frame.maxX,app.frame.width*0.8,"Night toggle sits at the bottom right")
        XCTAssertGreaterThan(toggle.frame.minY,app.frame.height*0.81,"Toggle stays below the cloud pixel band")
        XCTAssertEqual(toggle.frame.midY,app.buttons["Undo move"].frame.midY,accuracy:2,"Toggle shares the dock baseline")
        XCTAssertEqual(toggle.label,"Night mode");XCTAssertEqual(toggle.value as? String,"Off")
        XCTAssertEqual(puzzleValues(app)["night"],"0")
        let tiles=app.otherElements["board-plane-d4"].frame.union(app.otherElements["board-plane-e5"].frame)
        let texts=app.staticTexts.count
        let skyBefore=meanLuminance(app,crop:nil),boardBefore=meanLuminance(app,crop:tiles)
        toggle.tap();Thread.sleep(forTimeInterval:0.4)
        let skyAfter=meanLuminance(app,crop:nil),boardAfter=meanLuminance(app,crop:tiles)
        XCTAssertLessThan(skyAfter,skyBefore*0.6,"Night sky must darken the cloud band (\(skyBefore) -> \(skyAfter))")
        XCTAssertLessThan(boardAfter,boardBefore*0.9,"Board darkens at night (\(boardBefore) -> \(boardAfter))")
        XCTAssertGreaterThan(boardAfter,boardBefore*0.55,"Board stays readable at night (\(boardBefore) -> \(boardAfter))")
        XCTAssertEqual(puzzleValues(app)["night"],"1");XCTAssertEqual(toggle.value as? String,"On")
        XCTAssertEqual(app.staticTexts.count,texts);XCTAssertFalse(app.staticTexts["White to solve"].exists)
        XCTAssertTrue(app.buttons["square-e2"].isHittable,"Board input unaffected by night")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Night mode";shot.lifetime = .keepAlways;add(shot)
        app.terminate();app.launchArguments=["--uitesting","--preserve-style","--preserve-coach","--reduced-motion"];app.launch();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["night"],"1","Night persists across launches")
        XCTAssertEqual(app.buttons["night-toggle"].value as? String,"On")
        app.buttons["night-toggle"].tap()
        XCTAssertEqual(puzzleValues(app)["night"],"0");XCTAssertEqual(app.buttons["night-toggle"].value as? String,"Off")
    }
    /// The solver's pieces pulse briefly at every reveal; no side text is drawn.
    func testSidePulseOnEveryReveal() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1"];app.launch();puzzleReady(app)
        let status=app.otherElements["puzzle-status"]
        expectSidePulse(app,"1","One pulse per reveal")
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="Side pulse";shot.lifetime = .keepAlways;add(shot)
        XCTAssertEqual(puzzleValues(app)["boardMatches"],"1")
        XCTAssertFalse(app.staticTexts["Playing as White"].exists);XCTAssertFalse(app.staticTexts["Playing as Black"].exists)
        let gone=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulsing:0,"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[gone],timeout:4),.completed,"The pulse is brief and clears itself")
        XCTAssertEqual(puzzleValues(app)["hintMarks"],"0")
        let first=puzzleValues(app)["id"]!
        puzzleMove(app,puzzleValues(app)["next"]!)
        let changed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@ AND NOT value CONTAINS %@","ready:1,","id:\(first),"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:40),.completed)
        puzzleReady(app)
        expectSidePulse(app,"2","Journey reveal pulses again")
        app.buttons["Skip puzzle"].tap();app.buttons["confirm-action"].tap();puzzleReady(app)
        expectSidePulse(app,"3","Skip handoff pulses again")
        let settled=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulsing:0,"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[settled],timeout:4),.completed)
        XCTAssertEqual(puzzleValues(app)["hintMarks"],"0");XCTAssertEqual(puzzleValues(app)["boardMatches"],"1")
    }
    func testSidePulseReducedMotionIsStill() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-mate=1","--reduced-motion"];app.launch();puzzleReady(app)
        let status=app.otherElements["puzzle-status"]
        expectSidePulse(app,"1")
        XCTAssertTrue((app.otherElements["piece-effects"].value as? String ?? "").contains("particles:0,"),"Reduce Motion adds no particles")
        let gone=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulsing:0,"),object:status)
        XCTAssertEqual(XCTWaiter.wait(for:[gone],timeout:3),.completed,"Reduced variant clears within two seconds")
    }
    func testCloudFieldActuallyMovesAndPauses() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=8x8"];app.launch();puzzleReady(app)
        XCTAssertTrue(app.buttons["square-e2"].waitForExistence(timeout:15))
        func cloudPixels()->Data {
            let image=app.screenshot().image.cgImage!
            let crop=image.cropping(to:CGRect(x:0,y:Double(image.height)*0.73,width:Double(image.width)*0.95,height:Double(image.height)*0.08))!
            let context=CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
            return Data(bytes:context.data!,count:crop.width*crop.height*4)
        }
        let before=cloudPixels();Thread.sleep(forTimeInterval:2.2);let after=cloudPixels()
        XCTAssertNotEqual(before,after,"Cloud field must visibly animate")
        app.buttons["Settings"].tap();app.buttons["Toggle motion"].tap()
        Thread.sleep(forTimeInterval:0.5)
        let paused=cloudPixels();Thread.sleep(forTimeInterval:2.2)
        XCTAssertEqual(paused,cloudPixels(),"Motion switch must actually pause the clouds")
        app.buttons["Toggle motion"].tap();app.buttons["Close settings"].tap()
        XCTAssertFalse(app.staticTexts["White to solve"].exists)
    }

    func testBoardStaysStraightAndStillWhileCloudsRespondToDrag() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=8x8","--cloud-validation","--solver=white"];app.launch();puzzleReady(app)
        XCTAssertTrue(app.buttons["cloud-front"].waitForExistence(timeout:15))
        XCTAssertEqual(app.otherElements["board-plane-a4"].frame.midY,app.otherElements["board-plane-h4"].frame.midY,accuracy:0.1)
        let horizontal=app.otherElements["board-plane-e4"].frame.midX-app.otherElements["board-plane-d4"].frame.midX
        let vertical=app.otherElements["board-plane-d4"].frame.midY-app.otherElements["board-plane-d5"].frame.midY
        XCTAssertGreaterThan(vertical/horizontal,0.78,"Bird’s-eye view must retain readable rank spacing")
        XCTAssertLessThan(vertical/horizontal,0.97,"The board should have gentle perspective compression")
        let nearSpan=app.otherElements["board-plane-h1"].frame.midX-app.otherElements["board-plane-a1"].frame.midX
        let farSpan=app.otherElements["board-plane-h8"].frame.midX-app.otherElements["board-plane-a8"].frame.midX
        XCTAssertGreaterThan(nearSpan/farSpan,1.08,"Near edge must appear larger in the shared perspective")
        XCTAssertLessThan(nearSpan/farSpan,1.25,"Perspective must remain restrained")
        func boardPixels()->Data {
            let image=app.screenshot().image.cgImage!
            let factor=CGFloat(image.width)/app.frame.width
            let rect=app.otherElements["board-plane-d4"].frame.union(app.otherElements["board-plane-e5"].frame)
            let crop=image.cropping(to:CGRect(x:rect.minX*factor,y:rect.minY*factor,width:rect.width*factor,height:rect.height*factor))!
            let context=CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
            return Data(bytes:context.data!,count:crop.width*crop.height*4)
        }
        func assertBoardUnchanged(_ before:Data,_ after:Data) {
            XCTAssertEqual(before.count,after.count)
            let maximum=zip(before,after).map{abs(Int($0)-Int($1))}.max() ?? 0
            // HDR quantization can dither a channel by one code value without
            // moving an edge. A one-pixel shift across a tile exceeds this by >100.
            XCTAssertLessThanOrEqual(maximum,1,"Stationary board pixels changed beyond HDR rounding")
        }
        // The side pulse scales the solver's pieces at reveal; sample the board once it has settled.
        let announced=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@","sidePulsing:0,"),object:app.otherElements["puzzle-status"])
        XCTAssertEqual(XCTWaiter.wait(for:[announced],timeout:8),.completed)
        let frame=app.otherElements["board-plane-d4"].frame
        let original=boardPixels();Thread.sleep(forTimeInterval:2)
        assertBoardUnchanged(original,boardPixels())
        XCTAssertEqual(frame,app.otherElements["board-plane-d4"].frame)
        let cloud=app.buttons["cloud-front"]
        XCTAssertEqual(cloud.value as? String,"Calm")
        func cloudPixels()->Data {
            let image=app.screenshot().image.cgImage!
            let factor=CGFloat(image.width)/app.frame.width
            let rect=cloud.frame.insetBy(dx:-30,dy:-5)
            let crop=image.cropping(to:CGRect(x:rect.minX*factor,y:rect.minY*factor,width:rect.width*factor,height:rect.height*factor))!
            let context=CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
            return Data(bytes:context.data!,count:crop.width*crop.height*4)
        }
        let untouched=cloudPixels()
        let start=cloud.coordinate(withNormalizedOffset:CGVector(dx:0.30,dy:0.5))
        start.press(forDuration:0.2,thenDragTo:start.withOffset(CGVector(dx:65,dy:-3)))
        XCTAssertNotEqual(untouched,cloudPixels(),"With ambient wind frozen, a drag must visibly deform the rendered density")
        XCTAssertEqual(cloud.value as? String,"Stirred","The actual cloud pan recognizer must receive the drag")
        assertBoardUnchanged(original,boardPixels())
        XCTAssertEqual(frame,app.otherElements["board-plane-d4"].frame)
        XCTAssertFalse(app.staticTexts["White to solve"].exists)
        let attachment=XCTAttachment(screenshot:app.screenshot());attachment.name="Puffy interactive clouds and stationary board";attachment.lifetime = .keepAlways;add(attachment)
    }

    func testBoardStylesPreservePuzzleAndPersist() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--collection-fixture","--board=8x8","--reduced-motion"];app.launch();puzzleReady(app)
        let id=puzzleValues(app)["id"]
        openCollection(app);app.buttons["collection-board-1"].tap()
        XCTAssertTrue(app.buttons["accept-skin"].waitForExistence(timeout:5))
        XCTAssertFalse(app.descendants(matching:.any)["collection-gallery"].exists)
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"0","Preview must not persist before acceptance")
        app.buttons["revert-skin"].tap()
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"0")
        openCollection(app);app.buttons["collection-board-1"].tap();app.buttons["accept-skin"].tap()
        XCTAssertEqual(puzzleValues(app)["id"],id);XCTAssertEqual(puzzleValues(app)["boardTheme"],"1")
        app.terminate();app.launchArguments=["--uitesting","--preserve-coach","--reduced-motion"];app.launch();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["boardTheme"],"1");XCTAssertEqual(puzzleValues(app)["ownedBoards"],"3")
    }
    func testInvalidDropsAndPuzzlePromotion() throws {
        continueAfterFailure=false
        let app=XCUIApplication();app.launchArguments=["--uitesting","--board=6x6","--puzzle-promotion"];app.launch();puzzleReady(app)
        let before=puzzleValues(app),move=before["next"]!
        XCTAssertEqual(move.count,5)
        let from=app.buttons["square-"+String(move.prefix(2))],to=app.buttons["square-"+String(move.dropFirst(2).prefix(2))]
        let origin=from.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        origin.press(forDuration:0.2,thenDragTo:app.buttons["cloud-front"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)))
        XCTAssertEqual(puzzleValues(app)["mistakes"],"0","Illegal/off-board drop is input, not chess evidence")
        XCTAssertEqual(puzzleValues(app)["id"],before["id"])
        origin.press(forDuration:0.2,thenDragTo:to.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)))
        XCTAssertTrue(app.buttons["Queen"].waitForExistence(timeout:5));XCTAssertTrue(app.buttons["Knight"].exists)
        XCTAssertEqual(puzzleValues(app)["completed"],"0")
        let names:[Character:String]=["q":"Queen","r":"Rook","b":"Bishop","n":"Knight"]
        app.buttons[names[move.last!]!].tap();puzzleReady(app)
        XCTAssertEqual(puzzleValues(app)["completed"],"1");XCTAssertFalse(app.staticTexts["White to solve"].exists)
    }
}
