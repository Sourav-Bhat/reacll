import '../db/database.dart';

/// Sample dataset loader — real content, not synthetic.
///
/// Seeds one genuine imported conversation (an ESG phase-2 onboarding meeting,
/// transcribed on-device with whisper base from a Google Recorder m4a) plus the
/// structured facts a real extraction pass would produce. Lets you exercise the
/// full pipeline — home list, detail + transcript, FTS search, people, person
/// page + brief — on real data before wiring live capture.
///
/// Idempotent: guarded by the `sample_loaded` setting so tapping twice is safe.
class SampleData {
  static const _flag = 'sample_loaded';

  static bool isLoaded(RecallDb db) => db.getSetting(_flag) == '1';

  /// Returns true if it seeded, false if it was already present.
  static bool load(RecallDb db) {
    if (isLoaded(db)) return false;

    // People. Sourav is the app owner ("you"); Andy ran the meeting.
    // NB: whisper mis-transcribed "Sourav" as Surab/Zuraab throughout the
    // audio — a real, load-bearing failure mode for a person-indexed app.
    // We tag the correct person here; the transcript keeps the raw errors.
    final andy = db.upsertPerson('Andy');
    final sourav = db.upsertPerson('Sourav');

    final when = DateTime(2026, 6, 25, 10, 30);
    final convId = db.createConversation(
      title: 'ESG Phase 2 — onboarding with Andy',
      happenedAt: when,
      durationSec: 880,
    );

    // Imported audio artifact (audio itself not bundled; transcript is canonical).
    final artifactId =
        db.addArtifact(convId, 'imported_audio', filePath: null, status: 'done');
    db.addTranscript(artifactId, convId, _esgTranscript);

    // Tags: participants + topic.
    db.tagPerson(convId, andy);
    db.tagPerson(convId, sourav);
    db.tagTopic(convId, db.upsertTopic('ESG Phase 2'));

    // ---- Facts a Phase-2 extraction would yield (FR-9) ----
    // Commitments
    db.addFact(conversationId: convId, kind: 'commitment', personId: andy,
        personName: 'Andy', dueHint: 'next week', confidence: 0.9,
        happenedAt: when,
        text: 'Email Rob to arrange the north-south resources kickoff (SOW signed).');
    db.addFact(conversationId: convId, kind: 'commitment', personId: andy,
        personName: 'Andy', confidence: 0.85, happenedAt: when,
        text: 'Check with Ben whether the phase-2 JIRA board / space is set up.');
    db.addFact(conversationId: convId, kind: 'commitment', personId: andy,
        personName: 'Andy', dueHint: 'next week', confidence: 0.9, happenedAt: when,
        text: 'Share the data-points tracker and do a 1:1 to bring Sourav up to speed.');
    db.addFact(conversationId: convId, kind: 'commitment', personId: andy,
        personName: 'Andy', dueHint: 'today', confidence: 0.8, happenedAt: when,
        text: 'Send the calendar invitations.');
    db.addFact(conversationId: convId, kind: 'commitment', personId: sourav,
        personName: 'Sourav', dueHint: 'next week', confidence: 0.9, happenedAt: when,
        text: 'Book a 1-hour deep-dive session for detailed phase-2 context.');
    db.addFact(conversationId: convId, kind: 'commitment', personId: sourav,
        personName: 'Sourav', confidence: 0.85, happenedAt: when,
        text: 'Request JIRA access to the phase-2 board.');

    // Decisions
    db.addFact(conversationId: convId, kind: 'decision', confidence: 0.85,
        happenedAt: when,
        text: 'Innovation model shifts: the digital team builds tools/platform '
            '(Claude, Foundry) for business teams to self-serve, maturing into '
            'fully-managed enterprise apps.');
    db.addFact(conversationId: convId, kind: 'decision', personId: sourav,
        personName: 'Sourav', confidence: 0.85, happenedAt: when,
        text: 'FDEs to be used in ESG phase 2 in line with best practice — '
            'Sourav owns this area.');
    db.addFact(conversationId: convId, kind: 'decision', confidence: 0.8,
        happenedAt: when,
        text: 'Goal: replicate the north-south FDE effectiveness elsewhere '
            'without the 440k/year cost.');

    // Facts about people
    db.addFact(conversationId: convId, kind: 'fact', personId: andy,
        personName: 'Andy', confidence: 0.85, happenedAt: when,
        text: 'Owns ESG emissions reporting; will not sign off on poor data '
            'quality (blocked the PMI integration last year).');
    db.addFact(conversationId: convId, kind: 'fact', personId: sourav,
        personName: 'Sourav', confidence: 0.9, happenedAt: when,
        text: 'Joined as innovation architect / FDE for ESG phase 2.');
    db.addFact(conversationId: convId, kind: 'fact', personName: 'Tyrone',
        confidence: 0.75, happenedAt: when,
        text: 'Tyrone left; engineering now covers architecture + digital-lab innovation.');

    // Open threads / risks
    db.addFact(conversationId: convId, kind: 'thread', personName: 'Rachel',
        confidence: 0.8, happenedAt: when,
        text: 'No project manager on phase 2 — Rachel is the sole change-sign-off '
            '(single approval bottleneck).');
    db.addFact(conversationId: convId, kind: 'thread', confidence: 0.85,
        happenedAt: when,
        text: 'PwC and EY both audit the same GHG KPI with different processes — '
            'Andy is pushing to consolidate to one audit.');
    db.addFact(conversationId: convId, kind: 'thread', confidence: 0.8,
        happenedAt: when,
        text: 'Data-quality gate can slow phase 2 (last year PMI integration was '
            'rejected on data quality).');
    db.addFact(conversationId: convId, kind: 'thread', personId: sourav,
        personName: 'Sourav', confidence: 0.85, happenedAt: when,
        text: "Sourav's JIRA phase-2 access still pending.");

    // Extraction already done (don't re-run against the Claude API).
    db.queueExtraction(convId);
    db.setExtractionStatus(convId, 'done');

    // A clarification that surfaces the real name-mismatch problem (FR-11).
    db.addClarification(convId,
        "The transcript says 'Surab' / 'Zuraab' — is this Sourav?",
        reason: 'Whisper mis-transcribed the name on far-field audio; '
            'confirm to link these facts to the right person.');

    db.setSetting(_flag, '1');
    return true;
  }

  /// Real whisper `base` transcript of the ESG onboarding meeting
  /// (Google Recorder, 2026-06-25). Kept verbatim, including its errors, so the
  /// sample reflects true on-device transcription quality.
  static const String _esgTranscript = r'''
Add some context here. So, Sourav joined as the innovation architect for digital lab. As you know, we've had some changes within the team. Tyrone has left, and hence engineering is looking after overall architecture, but also the digital lab innovation piece. And we've kind of changed some of our approach to innovation. I actually can show you a slide, because we're going to do a slide on it today. Previously, the team was helping do the innovation. When you've got an idea or an issue, come to us, and then we'll work with you, and we'll do it. But now, I think the overall approach is we're going to create the tools and the platform for you to do the innovation. So you can use Claude, or Foundry, or whatever, to kind of put together your solution. And there's also a way for us to kind of mature these capabilities. Originally, people are probably going to be doing the innovation themselves individually on probably individual use cases. And then when it makes sense for us to have these capabilities shared, to the wider team or teams, then we need to manage it in a more standard way, like more guardrails, yada, yada. And at the end, we're going to be putting together enterprise-grade applications and capabilities that everybody would use, but it's going to be fully managed. And it's going to be like a collaboration between the digital team that manages the overall structure and platform, and the different business teams that will contribute to it.

I think as a part of that, there's still going to be a lot of stuff that we need experts or people with the type of skill set that we need to solve. There's going to be problems that are maybe AI, machine learning related, that you really need somebody from that field to kind of understand — data scientists, possibly deep integration with certain complex systems like SAP, that type of stuff, where it makes sense to actually bring on board people that can actually do deep work. I think then this is where Sourav's area is right now. So basically, if we need somebody to come in, maybe a more bespoke piece of work, to take a look at that, to figure out what it means, to do all the data work, the AI/machine learning, the developed algorithms, that type of stuff. And we just call it FDEs, basically. And I think the way that we're kind of moving in ESG on how we're using FDEs in phase two is more in line with how FDEs should be used and how we want to manage that later on. So Sourav's area is this area. So that's why I want to kind of get us three together to kind of discuss the ESG phase two, what the plan is right now, how Sourav can help just make sure everything goes smoothly because we know there's no project manager now. It's all Rachel, right?

And also, we want to learn a bit more about what makes the north-south FDEs so effective so that we can replicate that in other areas without the 440k a year. So that's the context. Where we are right now, the SOW is done. It's signed. So the north-south resources, we're going to send Rob an email to say let's arrange for the kickoff or whatever next week because everything's green. So I've already started sending some documentation over — this is the output that we work towards every single year. These are the different data sources which feed into the output. So they know the kind of standard of what we need to deliver at the end.

Can we loop Sourav in? Absolutely. I think maybe at the beginning there's a bit more here because phase two, there's a lot of stuff that's already done in phase one. I think it'll take some time to just go through all of that and get our heads around it. And I can share anything and do a quick one-on-one if useful. That will really help just to bring me up to speed. I know I was looking at the SOW and what was in phase one but that's on a very high level. It's better to have a more detailed view of what we are trying to do in phase two and phase three. I've done a bit of a tracker as well which identifies all the different data points and what's needed for those data points to come across, the blockers. So hopefully that document also will help, and maybe if I put in some time with you next week we can go through the different line items.

Is there any Teams channel where you keep all these documents or projects? We've got a Teams chat which we've been using informally for phase one, and then there's Jira and Confluence which they've used to set the project up. Ben set it up because I don't have admin access — I asked him if he can add another space in Jira, for phase two basically, another board, so then I can start adding all the different action items that we need to address. So I'll check with Ben if that is done. I have access to Jira, I just need it added to that page.

The broad idea is that all of the different data points that we use for emissions reporting — for our lenders, for IIF and for our sustainability loan KPIs — instead of being manually taken from one place into another and then the emissions calculated from that using different factors, we're trying to build that into one place with the calculations in the back end so that it can spit out the emissions at an asset level rather than us having to go in and do that. And that will give us visibility of performance in real time, so where we are underperforming and likely to miss a KPI we can actually visualize it and then mitigate against it. For example, where we are consuming non-renewable energy that gives us higher emissions in those different markets, to combat that we can buy renewable energy certificates from another market and that will then zero out — so it's an accounting exercise in terms of our emissions. Just to have near real-time visibility of what that data looks like and how we can mitigate the risks.

Do you have any other external parties who are helping us to evaluate? We are audited by both PwC and EY on our emissions. PwC on two safety metrics — energy and GHG — and then EY on DEI, traceability, GHG. The really annoying thing is that both EY and PwC both audit the GHG KPI, which is our emissions KPI, but because they're different auditing firms they both have different processes for how they audit it, so it's essentially us going through two separate audits with the same information. Largely each year they come up with the same finding, which we're trying to push back on — this is a significant amount of time the team are having to spend. If both auditors are coming up with the same number, does that not tell you that we only need to audit once and the other can rely on that same report? It's not uncommon in the industry, but we're pushing back on that a bit at the moment.

What that does mean is that the data itself is interrogated thoroughly, which is why with the work that we're doing every control, every bit of process has to be documented, which means the data itself is usually very high quality compared to a lot of other things we're seeing in other systems. So whilst it does cause a lot more work, the output is a lot higher quality. One thing that slowed us down last year was that PMI really wanted to say we've integrated that, but then when we started drilling into it I wasn't happy with the data quality, so I wasn't happy to sign off on stuff, which meant we had to go back and do more validation rounds. That can cause some slowdowns but ultimately it's the right thing to do.

It will be really helpful for me to also understand what's the health check of the project now and if there are any risks or concerns that you see that can come in phase two, so I can be aware of it, and while we are working on those FDEs we are setting the expectations right and looking at the right set of deliveries. Let's chat on that in our next 1:1 — I'll find some time next week, probably one hour because I'll need more detail. Next week I'll be in Madrid, but if you find a time that works I can probably accommodate, and I'll go through the tracker with you which has the extra level of detail. I've sent the invitations now. And if there are any ongoing meetings, do include me on those calls. For Jira access we can talk to Willem or Ben or Maxime — I actually have access. Most of the time I ask Ina and she gives me access, and we'll talk to Carlos because we have that Jira admin. Cool, we'll sort it out. Thanks for the call.
''';
}
