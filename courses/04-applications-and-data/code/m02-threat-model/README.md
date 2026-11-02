# Module 2 lab: threat model the Connected Equipment API

This folder holds the model from the demo "Threat model the Connected Equipment API". Open it in the
Microsoft Threat Modeling Tool, read the threats the tool generates from the design, and decide which
one becomes this sprint's requirement. Nothing deploys and nothing costs money.

Globomantics is a fictional company. Every name in this model is invented for teaching.

## What's in the folder

| File | What it is |
|---|---|
| `ConnectedEquipment-API.tm7` | The saved model: four elements, three flows, one trust boundary, and the repudiation threat already carrying its requirement |
| `threat-register.csv` | An authored design register that maps STRIDE threats to mitigations, owners and acceptance evidence. It's a design input written by hand, not output from the tool |
| `design-model.json` | The same design in plain JSON, so you can follow along without the tool |
| `README.md` | This guide |

## Before you start

Download the free Microsoft Threat Modeling Tool from `https://aka.ms/threatmodelingtool` and open it
once so it updates itself. It needs no Azure subscription and no sign-in.

## Read the model

1. **Open it.** Select Open a Model, then Open From this Computer, and pick
   `ConnectedEquipment-API.tm7`. It opens in Design view: Partner client, API Management, Order
   service and Order records, with a dotted trust boundary between API Management and the order
   service.
2. **Generate the threats.** Select the Analysis view icon, the file with a magnifying glass. The
   Threat List fills with threats the tool generated from the diagram, sorted by STRIDE category.
   Read every category, so you don't check only the threat types you already know.
3. **Find the requirement.** Select the Repudiation threat on the flow named Forwarded cancel request.
   Its Threat Properties show the title, the STRIDE category, and a status of Needs Investigation,
   and its justification holds the requirement: record the verified actor, partner, order, action,
   UTC time and outcome for every cancellation attempt, in an audit store operators can't edit.
4. **Compare the spoofing threat on the same hop.** Select the Spoofing threat on Forwarded cancel
   request. Authentication closes this one, not audit evidence: API Management should authenticate to
   the order service with a managed identity, so it never stores a credential someone could steal.
5. **Save the review.** Select Reports, then Create Full Report, then Save Report. The report proves
   you reviewed the design, not that the API passed a test, so the status stays open.

**A privacy tip.** Editing a threat stamps it with your Windows account name in the Changed By field.
If you share a model outside your team, check that field first.

## Build it yourself

To rebuild the model from scratch, select Create a Model with the Azure Threat Model Template. Add
Partner client as an external interactor, API Management as a generic process, Order service as a
process converted to the Web API stencil (right-click it, then Convert To, then Web API), and Order
records as a generic data store. The Web API stencil matters, because this template generates threats
only for its Azure and web stencils, so an all-generic model leaves the threat list empty. Add the
flows Cancel request, Forwarded cancel request and Order status write, then draw a trust boundary
between API Management and Order service and name it Trust boundary.

## Clean up

There's nothing to remove, because nothing deploys.
